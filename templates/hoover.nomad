job "hoover" {
  datacenters = ["dc1"]
  type = "service"

  group "deps" {
    task "es" {
      driver = "docker"
      config {
        image = "docker.elastic.co/elasticsearch/elasticsearch-oss:6.2.4"
        args = ["/bin/sh", "-c", "chown -R 1000:1000 /usr/share/elasticsearch/data && echo chown done && /usr/local/bin/docker-entrypoint.sh"]
        volumes = [
          "${liquid_volumes}/hoover/es/data:/usr/share/elasticsearch/data",
        ]
        port_map {
          es = 9200
        }
        labels {
          liquid_task = "hoover-es"
        }
      }
      env {
        cluster.name = "hoover"
        ES_JAVA_OPTS = "-Xms1536m -Xmx1536m"
      }
      resources {
        memory = 2048
        network {
          port "es" {}
        }
      }
      service {
        name = "hoover-es"
        port = "es"
      }
    }

    task "pg" {
      driver = "docker"
      config {
        image = "postgres:9.6"
        volumes = [
          "${liquid_volumes}/hoover/pg/data:/var/lib/postgresql/data",
        ]
        labels {
          liquid_task = "hoover-pg"
        }
        port_map {
          pg = 5432
        }
      }
      env {
        POSTGRES_USER = "hoover"
        POSTGRES_DATABASE = "hoover"
      }
      resources {
        memory = 1024
        network {
          port "pg" {}
        }
      }
      service {
        name = "hoover-pg"
        port = "pg"
      }
    }
  }

  group "web" {
    task "search" {
      driver = "docker"
      config {
        image = "liquidinvestigations/hoover-search"
        volumes = [
          ${hoover_search_repo}
          "${liquid_volumes}/hoover-ui/build:/opt/hoover/ui/build",
        ]
        port_map {
          http = 80
        }
        labels {
          liquid_task = "hoover-search"
        }
      }
      template {
        data = <<EOF
          {{- if keyExists "liquid_debug" }}
            DEBUG = {{key "liquid_debug"}}
          {{- end }}
          {{- with secret "liquid/hoover/search.django" }}
            SECRET_KEY = {{.Data.secret_key}}
          {{- end }}
          {{- range service "hoover-pg" }}
            HOOVER_DB = postgresql://hoover:hoover@{{.Address}}:{{.Port}}/hoover
          {{- end }}
          {{- range service "hoover-es" }}
            HOOVER_ES_URL = http://{{.Address}}:{{.Port}}
          {{- end }}
          HOOVER_HOSTNAME = hoover.{{key "liquid_domain"}}
          {{- with secret "liquid/hoover/search.oauth2" }}
            LIQUID_AUTH_PUBLIC_URL = http://{{key "liquid_domain"}}
            {{- range service "core" }}
              LIQUID_AUTH_INTERNAL_URL = http://{{.Address}}:{{.Port}}
            {{- end }}
            LIQUID_AUTH_CLIENT_ID = {{.Data.client_id}}
            LIQUID_AUTH_CLIENT_SECRET = {{.Data.client_secret}}
          {{- end }}
        EOF
        destination = "local/hoover.env"
        env = true
      }
      resources {
        memory = 512
        network {
          port "http" {}
        }
      }
      service {
        name = "hoover"
        port = "http"
      }
    }
  }

  group "collections" {
    task "nginx" {
      driver = "docker"
      template {
        data = <<EOF
          server {
            listen 80 default_server;

            {{- if service "hoover-es" }}
              {{- with service "hoover-es" }}
                {{- with index . 0 }}
                  location ~ ^/_es/(.*) {
                    proxy_pass http://{{ .Address }}:{{ .Port }}/$1;
                  }
                {{- end }}
              {{- end }}
            {{- end }}

            {{- range services }}
              {{- if .Name | regexMatch "^snoop-" }}
                {{- with service .Name }}
                  {{- with index . 0 }}
                    location ~ ^/{{ .Name | regexReplaceAll "^(snoop-)" "" }}/(.*) {
                      proxy_pass http://{{ .Address }}:{{ .Port }}/$1;
                      proxy_set_header Host {{ .Name | regexReplaceAll "^(snoop-)" "" }}.snoop.{{ key "liquid_domain" }};
                    }
                  {{- end }}
                {{- end }}
              {{- end }}
            {{- end }}

          }

          {{- range services }}
            {{- if .Name | regexMatch "^snoop-" }}
              {{- with service .Name }}
                {{- with index . 0 }}
                  server {
                    listen 80;
                    server_name {{ .Name | regexReplaceAll "^(snoop-)" "" }}.snoop.{{ key "liquid_domain" }};
                    location / {
                      proxy_pass http://{{ .Address }}:{{ .Port }};
                      proxy_set_header Host $host;
                    }
                  }
                {{- end }}
              {{- end }}
            {{- end }}
          {{- end }}

          {{- if service "zipkin" }}
            {{- with service "zipkin" }}
              {{- with index . 0 }}
                server {
                  listen 80;
                  server_name zipkin.{{ key "liquid_domain" }};
                  location / {
                    proxy_pass http://{{ .Address }}:{{ .Port }};
                    proxy_set_header Host $host;
                  }
                }
              {{- end }}
            {{- end }}
          {{- end }}
          EOF
        destination = "local/collections.conf"
      }
      config = {
        image = "nginx"
        port_map {
          nginx = 80
        }
        volumes = [
          "local/collections.conf:/etc/nginx/conf.d/collections.conf",
        ]
        labels {
          liquid_task = "hoover-collections-nginx"
        }
      }
      resources {
        memory = 256
        network {
          port "nginx" {
            static = 8765
          }
        }
      }
      service {
        name = "hoover-collections"
        port = "nginx"
      }
    }
  }
}