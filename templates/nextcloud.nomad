{% from '_lib.hcl' import shutdown_delay, authproxy_group, group_disk, task_logs, continuous_reschedule with context -%}

job "nextcloud" {
  datacenters = ["dc1"]
  type = "service"
  priority = 65

  group "nextcloud" {
    ${ group_disk() }
    ${ continuous_reschedule() }

    task "nextcloud" {
      ${ task_logs() }

      constraint {
        attribute = "{% raw %}${meta.liquid_volumes}{% endraw %}"
        operator = "is_set"
      }
      constraint {
        attribute = "{% raw %}${meta.liquid_collections}{% endraw %}"
        operator = "is_set"
      }

      driver = "docker"
      config {
        privileged = true  # for internal bind mount
        force_pull = true
        image = "${config.image('liquid-nextcloud')}"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/nextcloud/nextcloud19:/var/www/html",
        ]
        args = ["/bin/bash", "/local/cmd.sh"]
        port_map {
          http = 80
        }
        labels {
          liquid_task = "nextcloud"
        }
        memory_hard_limit = ${3 * config.nextcloud_memory_limit}
      }

      resources {
        cpu = 100
        memory = ${config.nextcloud_memory_limit}
        network {
          mbits = 1
          port "http" {}
        }
      }

      env {
        NEXTCLOUD_URL = "${config.liquid_http_protocol}://nextcloud.${config.liquid_domain}"
        NEXTCLOUD_HOST = "nextcloud.${config.liquid_domain}"

        LIQUID_TITLE = "${config.liquid_title}"
        LIQUID_CORE_URL = "${config.liquid_core_url}"
        NEXTCLOUD_UPDATE = "1"

        OVERWRITEHOST = "nextcloud.${config.liquid_domain}"
        OVERWRITEPROTOCOL = "${config.liquid_http_protocol}"
        OVERWRITEWEBROOT = "/"
        HTTP_PROTO = "${config.liquid_http_protocol}"

        POSTGRES_DB = "nextcloud"
        POSTGRES_USER = "nextcloud"

        OBJECTSTORE_S3_BUCKET = "nextcloud"
        OBJECTSTORE_S3_PORT = "9992"
        OBJECTSTORE_S3_SSL = "false"
        #OBJECTSTORE_S3_REGION = ""
        OBJECTSTORE_S3_USEPATH_STYLE = "true"
      }

      template {
        data = <<-EOF

        POSTGRES_HOST = "{{ env "attr.unique.network.ip-address" }}:9991"
        {{- with secret "liquid/nextcloud/nextcloud.postgres" }}
          POSTGRES_PASSWORD = {{.Data.secret_key | toJSON }}
        {{- end }}

        OBJECTSTORE_S3_HOST = "{{ env "attr.unique.network.ip-address" }}"
        {{- with secret "liquid/nextcloud/nextcloud.minio.key" }}
          OBJECTSTORE_S3_KEY = {{.Data.secret_key | toJSON }}
        {{- end }}
        {{- with secret "liquid/nextcloud/nextcloud.minio.secret" }}
          OBJECTSTORE_S3_SECRET = {{.Data.secret_key | toJSON }}
        {{- end }}

        EOF
        # TIMESTAMP = "${config.timestamp}"

        destination = "local/nextcloud.env"
        env = true
      }

      template {
        data = <<EOF
{% include 'nextcloud-setup.sh' %}
        EOF
        destination = "local/setup.sh"
        perms = "755"
      }

      template {
        data = <<EOF
{% include 'nextcloud-cmd.sh' %}
        EOF
        destination = "local/cmd.sh"
        perms = "755"
      }

      service {
        name = "nextcloud-app"
        port = "http"

        check {
          name = "http"
          initial_status = "critical"
          type = "http"
          path = "/status.php"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
          header {
            Host = ["nextcloud.${liquid_domain}"]
          }
        }
      }
    }
  }
}
