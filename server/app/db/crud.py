from sqlalchemy.orm import Session

from . import models, schemas


def get_chalk(db: Session, metadata_id: str) -> models.Chalk:
    return db.query(models.Chalk).get(metadata_id)


def get_chalks(db: Session) -> list[models.Chalk]:
    return db.query(models.Chalk).all()


def add_chalk(db: Session, chalk: schemas.Chalk) -> models.Chalk:
    db_chalk = models.Chalk(
        chalk_id=chalk.id,
        metadata_hash=chalk.metadata_hash,
        metadata_id=chalk.metadata_id,
        raw=chalk.raw,
    )
    db.add(db_chalk)
    db.commit()
    return db_chalk


def add_chalks(db: Session, chalks: list[schemas.Chalk]) -> list[models.Chalk]:
    db_chalks = [
        models.Chalk(
            chalk_id=chalk.id,
            metadata_hash=chalk.metadata_hash,
            metadata_id=chalk.metadata_id,
            raw=chalk.raw,
        )
        for chalk in chalks
    ]
    db.add_all(db_chalks)
    db.commit()
    return db_chalks


def add_stat(db: Session, stat: schemas.Stat) -> models.Chalk:
    db_stat = models.Stats(
        operation=stat.operation,
        timestamp=stat.timestamp,
        op_chalk_count=stat.op_chalk_count,
        op_chalker_commit_id=stat.op_chalker_commit_id,
        op_chalker_version=stat.op_chalker_version,
        op_platform=stat.op_platform,
    )
    db.add(db_stat)
    db.commit()
    return db_stat


def add_stats(db: Session, stats: list[schemas.Stat]) -> list[models.Chalk]:
    db_stats = [
        models.Stats(
            operation=stat.operation,
            timestamp=stat.timestamp,
            op_chalk_count=stat.op_chalk_count,
            op_chalker_commit_id=stat.op_chalker_commit_id,
            op_chalker_version=stat.op_chalker_version,
            op_platform=stat.op_platform,
        )
        for stat in stats
    ]
    db.add_all(db_stats)
    db.commit()
    return db_stats
