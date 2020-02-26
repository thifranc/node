import logging
import subprocess
from pathlib import Path
from time import time, sleep

from liquid_node.configuration import config
from liquid_node.nomad import nomad
from liquid_node.jsonapi import JsonApi

log = logging.getLogger(__name__)


def backup(dest, *targets):
    for name in config.collections:
        dest = Path(dest).resolve() / f"collection-{name}"
        dest.mkdir(parents=True, exist_ok=True)
        backup_collection(dest, name)


def backup_collection_pg(dest, name):
    dest_file = dest / "pg.sql.gz"
    log.info(f"Dumping collection {name} pg to {dest_file}")
    cmd = (
        f"./liquid dockerexec snoop-testdata-pg "
        f"pg_dump -U snoop -Ox -t 'data_*' -t django_migrations "
        f"| gzip -1 > {dest_file}"
    )
    subprocess.check_call(cmd, shell=True)


def backup_collection_blobs(dest, name):
    dest_file = dest / "blobs.tgz"
    log.info(f"Dumping collection {name} blobs to {dest_file}")
    cmd = (
        f"./liquid dockerexec snoop-testdata-api "
        f"tar c -C blobs . "
        f"| gzip -1 > {dest_file}"
    )
    subprocess.check_call(cmd, shell=True)


def backup_collection_es(dest, name):
    dest_file = dest / "es.tgz"
    log.info(f"Dumping collection {name} es snapshot to {dest_file}")
    es = JsonApi(f"http://{nomad.get_address()}:8765/_es")
    try:
        es.put(f"/_snapshot/backup-{name}", {
            "type": "fs",
            "settings": {
                "location": f"/es_repo/backup-{name}",
            },
        })
        es.put(f"/_snapshot/backup-{name}/snapshot", {
            "indices": name,
            "include_global_state": False,
        })
        t0 = time()
        while True:
            res = es.get(f"/_snapshot/backup-{name}/snapshot")
            snapshot = res["snapshots"][0]
            if snapshot.get("state") == "IN_PROGRESS":
                sleep(1)
                continue
            elif snapshot.get("state") == "SUCCESS":
                break
            else:
                raise RuntimeError("Something went wrong: %r" % snapshot)
        log.info(f"Snapshot done in {int(time()-t0)}s")
        tar_cmd = (
            f"./liquid dockerexec hoover-es "
            f"tar c -C /es_repo/backup-{name} . "
            f"| gzip -1 > {dest_file}"
        )
        subprocess.check_call(tar_cmd, shell=True)
    finally:
        es.delete(f"/_snapshot/backup-{name}/snapshot")
        es.delete(f"/_snapshot/backup-{name}")
        rm_cmd = (
            f"./liquid dockerexec hoover-es "
            f"rm -rf /es_repo/backup-{name} "
        )
        subprocess.check_call(rm_cmd, shell=True)


def backup_collection(dest, name):
    backup_collection_pg(dest, name)
    backup_collection_blobs(dest, name)
    backup_collection_es(dest, name)