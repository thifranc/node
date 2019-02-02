job "liquid" {
  datacenters = ["dc1"]
  type = "service"

  group "liquidnode" {
    count = 1

    task "core" {
      driver = "docker"
      config {
        image = "liquidinvestigations/core"
        port_map {
          http = 8000
        }
      }
      resources {
        network {
          port "http" {}
        }
      }
      service {
        name = "core"
        tags = ["global", "app"]
        port = "http"
      }
    }

    task "nginx" {
      driver = "docker"
      template {
        data = <<EOF

          {{- if service "core" }}
            upstream core {
              {{- range service "core" }}
                server {{ .Address }}:{{ .Port }} fail_timeout=1s;
              {{- end }}
            }
            server {
              listen 80;
              server_name liquid.example.org;
              location / {
                proxy_pass http://core;
                proxy_set_header Host $host;
              }
            }
          {{- end }}

          {{- if service "snoop-testdata-api" }}
            upstream snoop-testdata-api {
              {{- range service "snoop-testdata-api" }}
                server {{ .Address }}:{{ .Port }} fail_timeout=1s;
              {{- end }}
            }
            server {
              listen 80;
              server_name testdata.snoop.liquid.example.org;
              location / {
                proxy_pass http://snoop-testdata-api;
                proxy_set_header Host $host;
              }
            }
          {{- end }}

          EOF
        destination = "local/core.conf"
      }
      config = {
        image = "nginx"
        port_map {
          http = 80
        }
        volumes = [
          "local/core.conf:/etc/nginx/conf.d/core.conf",
        ]
      }
      resources {
        network {
          port "http" {
            static = 80
          }
        }
      }
      service {
        name = "nginx"
        tags = ["global"]
        port = "http"
      }
    }
  }
}
