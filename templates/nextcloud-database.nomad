{% from '_lib.hcl' import shutdown_delay, authproxy_group with context -%}

job "nextcloud-database" {
  datacenters = ["dc1"]
  type = "service"
  priority = 100

  group "nextcloud-database" {
    network {
      mode = "bridge"
    }

    service {
      name = "nextcloud-pg"
      port = "5432"

      connect { sidecar_service {} }
    }

    task "nextcloud-database" {
      constraint {
        attribute = "{% raw %}${meta.liquid_volumes}{% endraw %}"
        operator = "is_set"
      }

      driver = "docker"
      ${ shutdown_delay() }
      config {
        image = "postgres:12"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/nextcloud/postgres12:/var/lib/postgresql/data",
        ]
        labels {
          liquid_task = "nextcloud-pg"
        }
        #port_map {
        #  pg = 5432
        #}
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
      }

      template {
        data = <<-EOF
        POSTGRES_DB = "nextcloud"
        POSTGRES_USER = "nextcloudAdmin"

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
          #port pg {}
        }
      }
    }
  }
}
