import os
import json
import logging
from typing import Any, Dict, List

import ydb

YDB_ENDPOINT = os.getenv("YDB_ENDPOINT")
YDB_DATABASE = os.getenv("YDB_DATABASE")

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def get_all_docs() -> List[Dict[str, str]]:
    """
    Returns all documents from the docs table.
    """
    driver = ydb.Driver(
        endpoint=YDB_ENDPOINT,
        database=YDB_DATABASE,
        credentials=ydb.iam.MetadataUrlCredentials(),
    )

    docs: List[Dict[str, str]] = []

    try:
        driver.wait(fail_fast=True, timeout=5)
        session = driver.table_client.session().create()

        query = """
        SELECT
            id,
            name,
            url
        FROM docs;
        """

        result = session.transaction().execute(query, commit_tx=True)

        for row in result[0].rows:
            docs.append(
                {
                    "id": str(row.id),
                    "name": row.name,
                    "url": row.url,
                }
            )

        logger.info("Fetched %d documents from DB", len(docs))

    except Exception:
        logger.exception("Failed to fetch documents from DB")

    finally:
        driver.stop()

    return docs


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Cloud Function entrypoint.
    """
    docs = get_all_docs()

    return {
        "statusCode": 200,
        "body": json.dumps(docs, ensure_ascii=False),
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
    }
