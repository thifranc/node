#!/usr/bin/env python3

"""
A tool for quick-and-dirty actions on a nomad liquid cluster.

https://half-life.fandom.com/wiki/Crowbar
"""

import os
import logging
import subprocess
from urllib.request import Request, urlopen
import json
from base64 import b64decode
import argparse

DEBUG = os.environ.get('DEBUG', '').lower() in ['on', 'true']
LOG_LEVEL = logging.DEBUG if DEBUG else logging.INFO

log = logging.getLogger(__name__)
log.setLevel(LOG_LEVEL)


def run(cmd):
    log.debug("+ %s", cmd)
    return subprocess.check_output(cmd, shell=True).decode('latin1')


def run_fg(cmd, **kwargs):
    kwargs.setdefault('shell', True)
    subprocess.check_call(cmd, **kwargs)


class Docker:

    def containers(self, labels=[]):
        label_args = ' '.join(f'-f label={k}={v}' for k, v in labels)
        out = run(f'docker ps -q {label_args}')
        return out.split()


class JsonApi:

    def __init__(self, endpoint):
        self.endpoint = endpoint

    def request(self, method, url, data=None):
        req_url = f'{self.endpoint}{url}'
        req_headers = {}
        req_body = None

        if data is not None:
            if isinstance(data, bytes):
                req_body = data

            else:
                req_headers['Content-Type'] = 'application/json'
                req_body = json.dumps(data).encode('utf8')

        log.debug('%s %r %r', method, req_url, data)
        req = Request(
            req_url,
            req_body,
            req_headers,
            method=method,
        )

        with urlopen(req) as res:
            res_body = json.load(res)
            log.debug('response: %r', res_body)
            return res_body

    def get(self, url):
        return self.request('GET', url)

    def put(self, url, data):
        return self.request('PUT', url, data)


class Nomad(JsonApi):

    def __init__(self, endpoint='http://127.0.0.1:4646'):
        super().__init__(endpoint + '/v1/')

    def job_allocations(self, job):
        return nomad.get(f'job/{job}/allocations')

    def agent_members(self):
        return self.get('agent/members')['Members']


class Consul(JsonApi):

    def __init__(self, endpoint='http://127.0.0.1:8500'):
        super().__init__(endpoint + '/v1/')

    def set_kv(self, key, value):
        assert self.put(f'kv/{key}', value.encode('latin1'))


docker = Docker()
nomad = Nomad()
consul = Consul()


def first(items, name_plural='items'):
    assert items, f"No {name_plural} found"

    if len(items) > 1:
        log.warning(
            f"Found multiple {name_plural}: %r, choosing the first one",
            items,
        )

    return items[0]


def shell(name, *args):
    """
    Open a shell in a docker container tagged with liquid_task=`name`
    """
    containers = docker.containers([('liquid_task', name)])
    id = first(containers, 'containers')
    docker_exec_cmd = ['docker', 'exec', '-it', id] + list(args or ['bash'])
    run_fg(docker_exec_cmd, shell=False)


def alloc(job, group):
    """
    Print the ID of the current allocation of the job and group.
    """
    allocs = nomad.job_allocations(job)
    running = [
        a['ID'] for a in allocs
        if a['ClientStatus'] == 'running'
            and a['TaskGroup'] == group
    ]
    print(first(running, 'running allocations'))


def nomad_address():
    """
    Print the nomad server's address.
    """
    members = [m['Addr'] for m in nomad.agent_members()]
    print(first(members, 'members'))


def setdomain(domain):
    """
    Set the domain name for the cluster.
    """
    consul.set_kv('liquid_domain', domain)


def setdebug(value='on'):
    """
    Set debug flag. Use `on` to enable debugging.
    """
    consul.set_kv('liquid_debug', value)


class SubcommandParser(argparse.ArgumentParser):

    def add_subcommands(self, name, subcommands):
        subcommands_map = {c.__name__: c for c in subcommands}

        class SubcommandAction(argparse.Action):
            def __call__(self, parser, namespace, values, option_string=None):
                setattr(namespace, name, subcommands_map[values])

        self.add_argument(
            name,
            choices=[c.__name__ for c in subcommands],
            action=SubcommandAction,
        )


def main():
    parser = SubcommandParser(description=__doc__)
    parser.add_subcommands('cmd', [
        shell,
        alloc,
        nomad_address,
        setdomain,
        setdebug,
    ])
    (options, extra_args) = parser.parse_known_args()
    options.cmd(*extra_args)


if __name__ == '__main__':
    logging.basicConfig(
        level=LOG_LEVEL,
        format='%(asctime)s %(levelname)s %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S',
    )
    main()