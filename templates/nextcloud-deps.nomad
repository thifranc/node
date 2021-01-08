{% from '_lib.hcl' import shutdown_delay, group_disk, task_logs, continuous_reschedule with context -%}

job "nextcloud-deps" {
  datacenters = ["dc1"]
  type = "service"
  priority = 65

  group "nextcloud-pg" {
    task "nextcloud-pg" {
      constraint {
        attribute = "{% raw %}${meta.liquid_volumes}{% endraw %}"
        operator = "is_set"
      }
      affinity {
        attribute = "{% raw %}${meta.liquid_large_databases}{% endraw %}"
        value     = "true"
        weight    = 100
      }

      driver = "docker"
      ${ shutdown_delay() }
      config {
        image = "postgres:13"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/nextcloud/postgres13:/var/lib/postgresql/data",
        ]
        labels {
          liquid_task = "nextcloud-pg"
        }
        port_map {
          pg = 5432
        }
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
      }

      template {
        data = <<-EOF
        POSTGRES_DB = "nextcloud"
        POSTGRES_USER = "nextcloud"

        {{- with secret "liquid/nextcloud/nextcloud.postgres" }}
          POSTGRES_PASSWORD = {{.Data.secret_key | toJSON }}
        {{- end }}
        EOF
        destination = "local/db.env"
        env = true
      }

      resources {
        cpu = 100
        memory = 500
        network {
          mbits = 1
          port pg {}
        }
      }

      service {
        name = "nextcloud-pg"
        port = "pg"
        tags = ["fabio-:9991 proto=tcp"]

        check {
          name = "tcp"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }
  }

  group "nextcloud-minio" {
    task "nextcloud-minio" {
      constraint {
        attribute = "{% raw %}${meta.liquid_volumes}{% endraw %}"
        operator = "is_set"
      }
      affinity {
        attribute = "{% raw %}${meta.liquid_large_databases}{% endraw %}"
        value     = "true"
        weight    = 100
      }

      driver = "docker"
      ${ shutdown_delay() }
      config {
        image = "${config.image('minio')}"
        args = ["server", "/data"]
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/nextcloud/data-minio:/data",
        ]
        labels {
          liquid_task = "nextcloud-minio"
        }
        port_map {
          minio = 9000
        }
        memory_hard_limit = 2000
      }

      template {
        data = <<-EOF
        {{- with secret "liquid/nextcloud/nextcloud.minio.key" }}
          MINIO_ROOT_USER = {{.Data.secret_key | toJSON }}
          MINIO_ACCESS_KEY = {{.Data.secret_key | toJSON }}
        {{- end }}
        {{- with secret "liquid/nextcloud/nextcloud.minio.secret" }}
          MINIO_ROOT_PASSWORD = {{.Data.secret_key | toJSON }}
          MINIO_SECRET_KEY = {{.Data.secret_key | toJSON }}
        {{- end }}
        EOF
        destination = "local/minio.env"
        env = true
      }

      resources {
        cpu = 100
        memory = 300
        network {
          mbits = 1
          port minio {}
        }
      }

      service {
        name = "nextcloud-minio"
        port = "minio"
        tags = ["fabio-:9992 proto=tcp"]

        check {
          name = "tcp"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }
  }
}
