from liquid_node import jobs


class Drone(jobs.Job):
    name = 'drone'
    template = jobs.TEMPLATES / f'{name}.nomad'


class DroneWorkers(jobs.Job):
    name = 'drone-workers'
    template = jobs.TEMPLATES / f'{name}.nomad'
