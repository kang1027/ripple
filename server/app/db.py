from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from .config import get_settings


class Base(DeclarativeBase):
    pass


_engine = None
_sessionmaker: async_sessionmaker[AsyncSession] | None = None


def init_engine(url: str | None = None) -> None:
    global _engine, _sessionmaker
    _engine = create_async_engine(url or get_settings().database_url, pool_pre_ping=True)
    _sessionmaker = async_sessionmaker(_engine, expire_on_commit=False)


def engine():
    if _engine is None:
        init_engine()
    return _engine


def sessionmaker() -> async_sessionmaker[AsyncSession]:
    if _sessionmaker is None:
        init_engine()
    return _sessionmaker  # type: ignore[return-value]


async def create_all() -> None:
    from . import models  # noqa: F401  (테이블 등록)

    async with engine().begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(_add_missing_columns)


def _add_missing_columns(conn) -> None:
    """마이그레이션 도구 없이 쓰는 동안, 모델에 새로 생긴 nullable/기본값 컬럼을 기존 테이블에 더한다.
    컬럼을 지우거나 타입을 바꾸는 건 하지 않는다."""
    from sqlalchemy import inspect, text

    insp = inspect(conn)
    for table in Base.metadata.sorted_tables:
        if not insp.has_table(table.name):
            continue
        have = {c["name"] for c in insp.get_columns(table.name)}
        for col in table.columns:
            if col.name in have:
                continue
            ddl = col.type.compile(dialect=conn.dialect)
            default = ""
            if col.server_default is not None:
                default = f" DEFAULT {col.server_default.arg}"
            conn.execute(text(f'ALTER TABLE "{table.name}" ADD COLUMN "{col.name}" {ddl}{default}'))


async def get_session() -> AsyncIterator[AsyncSession]:
    async with sessionmaker()() as session:
        yield session
