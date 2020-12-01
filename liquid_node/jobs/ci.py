from liquid_node import jobs


class Drone(jobs.Job):
    name = 'drone'
    template = jobs.TEMPLATES / f'{name}.nomad'
    stage = 2
    vault_secret_keys = [
        'liquid/ci/vmck.django',
        'liquid/ci/vmck.postgres',
        'liquid/ci/drone.rpc.secret',
    ]


class Deps(jobs.Job):
    name = 'drone-deps'
    template = jobs.TEMPLATES / f'{name}.nomad'
    stage = 1


class DroneWorkers(jobs.Job):
    name = 'drone-workers'
    template = jobs.TEMPLATES / f'{name}.nomad'
    stage = 3
