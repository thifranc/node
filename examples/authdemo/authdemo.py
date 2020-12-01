from liquid_node import jobs


class AuthDemo(jobs.Job):
    name = 'authdemo'
    template = jobs.TEMPLATES / f'{name}.nomad'
    app = 'authdemo'
    stage = 2
    core_oauth_apps = [
        {
            'name': 'authdemo',
            'vault_path': 'liquid/authdemo/auth.oauth2',
            'callback': '/oauth2/callback',
        },
    ]
    vault_secret_keys = [
        'liquid/authdemo/auth.django',
    ]
