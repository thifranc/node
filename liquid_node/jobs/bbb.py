from liquid_node import jobs


class Deps(jobs.Job):
    name = 'bbb-deps'
    template = jobs.TEMPLATES / f'{name}.nomad'
    app = 'bbb'
    stage = 1
