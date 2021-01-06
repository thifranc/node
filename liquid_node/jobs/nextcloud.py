from liquid_node import jobs


class Nextcloud(jobs.Job):
    name = 'nextcloud'
    template = jobs.TEMPLATES / f'{name}.nomad'
    app = 'nextcloud'
    stage = 2
    core_oauth_apps = [
        {
            'name': 'nextcloud',
            'vault_path': 'liquid/nextcloud/auth.oauth2',
            'callback': '/oauth2/callback',
        },
    ]
    vault_secret_keys = [
        'liquid/nextcloud/nextcloud.minio.key',
        'liquid/nextcloud/nextcloud.minio.secret',
        'liquid/nextcloud/nextcloud.postgres',
    ]
    generate_oauth2_proxy_cookie = True


class Periodic(jobs.Job):
    name = 'nextcloud-periodic'
    template = jobs.TEMPLATES / f'{name}.nomad'
    app = 'nextcloud'
    stage = 3


class Proxy(jobs.Job):
    name = 'nextcloud-proxy'
    template = jobs.TEMPLATES / f'{name}.nomad'
    app = 'nextcloud'
    stage = 4


class Deps(jobs.Job):
    name = 'nextcloud-deps'
    template = jobs.TEMPLATES / f'{name}.nomad'
    app = 'nextcloud'
    stage = 1
