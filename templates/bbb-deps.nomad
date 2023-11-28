{% from '_lib.hcl' import set_pg_password_template, shutdown_delay, authproxy_group, task_logs, group_disk, continuous_reschedule with context -%}

job "bbb-deps" {
  datacenters = ["dc1"]
  type = "service"
  priority = 98

  group "deps" {
    ${ group_disk() }
    ${ continuous_reschedule() }

    task "postgres" {
      ${ task_logs() }
      leader = true

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
        image = "postgres:15"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/postgres/${config.liquid_domain}-pg-15:/var/lib/postgresql/data",
        ]
        labels {
          liquid_task = "bbb-pg"
        }
        port_map {
          bbb_pg = 5432
        }
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
        memory_hard_limit = 1000
      }

      template {
        data = <<-EOF
        POSTGRES_DB = "greenlight_production"
        POSTGRES_USER = "greenlight"
        POSTGRES_PASSWORD = "postgres_secret"
        POSTGRES_INITDB_ARGS = "--encoding=UTF-8 --lc-collate=C --lc-ctype=C"
        EOF
        destination = "local/pg.env"
        env = true
      }
      ${ set_pg_password_template('bbb') }

      resources {
        cpu = 100
        memory = 300
        network {
          mbits = 1
          port "bbb_pg" {}
        }
      }

      service {
        name = "bbb-pg"
        port = "bbb_pg"
        tags = ["fabio-:${config.port_bbb_pg} proto=tcp"]
        check {
          name = "pg_isready"
          type = "script"
          command = "/bin/sh"
          args = ["-c", "pg_isready"]
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "bbb-redis" {
      ${ task_logs() }
      constraint {
        attribute = "{% raw %}${meta.liquid_volumes}{% endraw %}"
        operator = "is_set"
      }
      ${ shutdown_delay() }

      driver = "docker"
      config {
        image = "${config.image('bbb-redis')}"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/redis/data:/data",
        ]
        port_map {
          redis = 6379
        }
        labels {
          liquid_task = "bbb-redis"
        }
      }

      resources {
        cpu = 500
        memory = 512
        network {
          port "redis" {}
          mbits = 1
        }
      }

      service {
        name = "bbb-redis"
        port = "redis"
        tags = ["fabio-:${config.port_bbb_redis} proto=tcp"]

        check {
          name = "bbb-redis-alive"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
        check_restart {
          limit = 5
          grace = "980s"
        }
      }
    }

    task "mongodb" {
      ${ task_logs() }
      leader = false

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
        image = "mongo:4.4"
        command = "mongod"
        #args = [ "--config" "/etc/mongod.conf" "--oplogSize" "8" --replSet rs0 "--noauth" ]
        args = [ "--config", "/etc/mongod.conf", "--oplogSize", "8", "--noauth"  ]
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/mongo/data.garbage:/data",
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/mongo/mongod.conf:/etc/mongod.conf",
        ]
        labels {
          liquid_task = "bbb-mongo"
        }
        port_map {
          mongo = 27017
        }
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
        memory_hard_limit = 1000
      }

      template {
        data = <<-EOF
            #!/bin/sh
            set -e

            #host=$\{HOSTNAME:-$(hostname -f)\}
            # shut down again
            mongod --pidfilepath /tmp/docker-entrypoint-temp-mongod.pid --shutdown
            # restart again binding to 0.0.0.0 to allow a replset
            mongod --oplogSize 8 --replSet rs0 --noauth \
               --config /tmp/docker-entrypoint-temp-config.json \
               --bind_ip 0.0.0.0 --port 27017 \
               --tlsMode disabled \
               --logpath /proc/1/fd/1 --logappend \
               --pidfilepath /tmp/docker-entrypoint-temp-mongod.pid --fork
            
            # init replset with defaults
            mongo 127.0.0.1 --eval "rs.initiate({
               _id: 'rs0',
               members: [ { _id: 0, host: '{{ env "attr.unique.network.ip-address" }}:${config.port_bbb_mongo}' } ]
            })"
            
            echo "Waiting to become a master"
            echo 'while (!db.isMaster().ismaster) { sleep(100); }' | mongo
            
            echo "I'm the master!"
            EOF
        destination = "local/init-replica.sh"
        env = false
      }

      resources {
        cpu = 100
        memory = 300
        network {
          mbits = 1
          port "mongo" {}
        }
      }

      service {
        name = "bbb-mongo"
        port = "mongo"
        tags = ["fabio-:${config.port_bbb_mongo} proto=tcp"]
        check {
          name = "bbb-mongo"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "akka" {
      ${ task_logs() }
      leader = false

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

      env {
        DOMAIN = "bbb.${liquid_domain}"
        SHARED_SECRET = "bbb_secret"
        REDIS_HOST = "{% raw %}${attr.unique.network.ip-address}{% endraw %}"
        REDIS_PORT = "${config.port_bbb_redis}"
      }

      config {
        image = "piaille/apps-akka:1.0.0"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/vol-freeswitch:/var/freeswitch/meetings",
        ]
        labels {
          liquid_task = "bbb-apps-akka"
        }
        port_map {
          apps_akka = 8901
        }
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
        memory_hard_limit = 1000
      }

      resources {
        cpu = 100
        memory = 300
        network {
          mbits = 1
          port "apps_akka" {}
        }
      }

      service {
        name = "bbb-apps-akka"
        port = "apps_akka"
        tags = ["fabio-:${config.port_bbb_apps_akka} proto=tcp"]
        check {
          name = "bbb-apps-akka"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "web" {
      ${ task_logs() }
      leader = false

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

      env {
        DOMAIN = "bbb.${liquid_domain}"
        SHARED_SECRET = "bbb_secret"
        REDIS_HOST = "{% raw %}${attr.unique.network.ip-address}{% endraw %}"
        REDIS_PORT = "${config.port_bbb_redis}"
        DEV_MODE = "false"
        ENABLE_RECORDING = "false"
        WELCOME_MESSAGE = "welcome to BBB"
        WELCOME_FOOTER = "footer to BBB"
        STUN_SERVER = ""
        TURN_SERVER = ""
        TURN_SECRET = ""
        DISABLED_FEATURES = "chat, sharedNotes, polls, externalVideos, downloadPresentationWithAnnotations, learningDashboard, customVirtualBackgrounds, breakoutRooms, importSharedNotesFromBreakoutRooms, importPresentationWithAnnotationsFromBreakoutRooms, downloadPresentationConvertedToPdf"
        ENABLE_LEARNING_DASHBOARD = "false"
        NUMBER_OF_BACKEND_NODEJS_PROCESSES = "1"
      }

      config {
        image = "piaille/bbb-web:1.0.1"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/vol-freeswitch:/var/freeswitch/meetings",
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/var_bigbluebutton:/var/bigbluebutton",
        ]
        labels {
          liquid_task = "bbb-web"
        }
        port_map {
          bbb_web = 8090
        }
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
        memory_hard_limit = 1000
      }

      resources {
        cpu = 100
        memory = 300
        network {
          mbits = 1
          port "bbb_web" {}
        }
      }

      service {
        name = "bbb-web"
        port = "bbb_web"
        tags = ["fabio-:${config.port_bbb_web} proto=tcp"]
        check {
          name = "bbb-web"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "html5-front" {
      ${ task_logs() }
      leader = false

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

      env {
        DOMAIN = "bbb.${liquid_domain}"
        SHARED_SECRET = "bbb_secret"
        MONGO_HOST = "{% raw %}${attr.unique.network.ip-address}{% endraw %}"
        MONGO_PORT = "${config.port_bbb_mongo}"
        REDIS_HOST = "{% raw %}${attr.unique.network.ip-address}{% endraw %}"
        REDIS_PORT = "${config.port_bbb_redis}"
        DEV_MODE = "false"
        ENABLE_RECORDING = "false"
        WELCOME_MESSAGE = "welcome to BBB"
        WELCOME_FOOTER = "footer to BBB"
        STUN_SERVER = ""
        TURN_SERVER = ""
        TURN_SECRET = ""
        DISABLED_FEATURES = "chat, sharedNotes, polls, externalVideos, downloadPresentationWithAnnotations, learningDashboard, customVirtualBackgrounds, breakoutRooms, importSharedNotesFromBreakoutRooms, importPresentationWithAnnotationsFromBreakoutRooms, downloadPresentationConvertedToPdf"
        ENABLE_LEARNING_DASHBOARD = "false"
        NUMBER_OF_BACKEND_NODEJS_PROCESSES = "1"
        CLIENT_TITLE = "Bigbluebutton"
        LISTEN_ONLY_MODE = "true"
        DISABLE_ECHO_TEST = "false"
        AUTO_SHARE_WEBCAM = "false"
        DISABLE_VIDEO_PREVIEW = "false"
        CHAT_ENABLED = "false"
        CHAT_START_CLOSED = "true"
        BREAKOUTROOM_LIMIT = "2"
        BBB_HTML5_ROLE = "frontend"
        INSTANCE_ID = "1"
        PORT = "4100"
        WSURL = "wss://bbb.${liquid_domain}/bbb-webrtc-sfu"
      }

      template {
          destination = "local/bbb-html5.yml"
          data = <<EOF
public:
  app:
    bbbServerVersion: TAG_HTML5-docker
    listenOnlyMode: {{ env "LISTEN_ONLY_MODE" }}
    skipCheck: {{ env "DISABLE_ECHO_TEST" }}
    clientTitle: {{ env "CLIENT_TITLE" }}
    appName: BigBlueButton HTML5 Client (docker)
    breakouts:
      breakoutRoomLimit: {{ env "BREAKOUTROOM_LIMIT" }}
  kurento:
    wsUrl: {{ env "WSURL" }}
    autoShareWebcam: {{ env "AUTO_SHARE_WEBCAM" }}
    skipVideoPreview: {{ env "DISABLE_VIDEO_PREVIEW" }}
  chat:
    enabled: {{ env "CHAT_ENABLED" }}
    startClosed: {{ env "CHAT_START_CLOSED" }}
  pads:
    url: https://{{ env "DOMAIN" }}/pad
private:
  app:
    host: 0.0.0.0
  redis:
    host: {{ env "REDIS_HOST" }}
    port: {{ env "REDIS_PORT" }}
EOF
          }

      template {
        destination = "local/start.sh"
        data = <<EOF
cp /local/bbb-html5.yml /app/bbb-html5.yml
/entrypoint.sh
EOF
          }

      config {
        image = "piaille/bbb-html5:1.0.8"
        entrypoint = ["/bin/bash", "/local/start.sh"]
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/html5/static/:/html5-static",
        ]
        labels {
          liquid_task = "bbb-html5-front"
        }
        port_map {
          bbb-html5-front = 4100
        }
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
        memory_hard_limit = 1000
      }

      resources {
        cpu = 100
        memory = 300
        network {
          mbits = 1
          port "bbb-html5-front" {}
        }
      }

      service {
        name = "bbb-html5-front"
        port = "bbb-html5-front"
        tags = ["fabio-:${config.port_bbb_html5_front} proto=tcp"]
        check {
          name = "bbb-html5-front"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "html5-back" {
      ${ task_logs() }
      leader = false

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

      env {
        DOMAIN = "bbb.${liquid_domain}"
        SHARED_SECRET = "bbb_secret"
        MONGO_HOST = "{% raw %}${attr.unique.network.ip-address}{% endraw %}"
        MONGO_PORT = "${config.port_bbb_mongo}"
        REDIS_HOST = "{% raw %}${attr.unique.network.ip-address}{% endraw %}"
        REDIS_PORT = "${config.port_bbb_redis}"
        DEV_MODE = "false"
        ENABLE_RECORDING = "false"
        WELCOME_MESSAGE = "welcome to BBB"
        WELCOME_FOOTER = "footer to BBB"
        STUN_SERVER = ""
        TURN_SERVER = ""
        TURN_SECRET = ""
        DISABLED_FEATURES = "chat, sharedNotes, polls, externalVideos, downloadPresentationWithAnnotations, learningDashboard, customVirtualBackgrounds, breakoutRooms, importSharedNotesFromBreakoutRooms, importPresentationWithAnnotationsFromBreakoutRooms, downloadPresentationConvertedToPdf"
        ENABLE_LEARNING_DASHBOARD = "false"
        NUMBER_OF_BACKEND_NODEJS_PROCESSES = "1"
        CLIENT_TITLE = "Bigbluebutton"
        LISTEN_ONLY_MODE = "true"
        DISABLE_ECHO_TEST = "false"
        AUTO_SHARE_WEBCAM = "false"
        DISABLE_VIDEO_PREVIEW = "false"
        CHAT_ENABLED = "false"
        CHAT_START_CLOSED = "true"
        BREAKOUTROOM_LIMIT = "2"
        BBB_HTML5_ROLE = "backend"
        INSTANCE_ID = "1"
        PORT = "4000"
        WSURL = "wss://bbb.${liquid_domain}/bbb-webrtc-sfu"
      }

      template {
          destination = "local/bbb-html5.yml"
          data = <<EOF
public:
  app:
    bbbServerVersion: TAG_HTML5-docker
    listenOnlyMode: {{ env "LISTEN_ONLY_MODE" }}
    skipCheck: {{ env "DISABLE_ECHO_TEST" }}
    clientTitle: {{ env "CLIENT_TITLE" }}
    appName: BigBlueButton HTML5 Client (docker)
    breakouts:
      breakoutRoomLimit: {{ env "BREAKOUTROOM_LIMIT" }}
  kurento:
    wsUrl: {{ env "WSURL" }}
    autoShareWebcam: {{ env "AUTO_SHARE_WEBCAM" }}
    skipVideoPreview: {{ env "DISABLE_VIDEO_PREVIEW" }}
  chat:
    enabled: {{ env "CHAT_ENABLED" }}
    startClosed: {{ env "CHAT_START_CLOSED" }}
  pads:
    url: https://{{ env "DOMAIN" }}/pad
private:
  app:
    host: 0.0.0.0
  redis:
    host: {{ env "REDIS_HOST" }}
    port: {{ env "REDIS_PORT" }}
EOF
          }

      template {
        destination = "local/start.sh"
        data = <<EOF
cp /local/bbb-html5.yml /app/bbb-html5.yml
/entrypoint.sh
EOF
          }

      config {
        image = "piaille/bbb-html5:1.0.8"
        entrypoint = ["/bin/bash", "/local/start.sh"]
        labels {
          liquid_task = "bbb-html5-back"
        }
        port_map {
          bbb-html5-back = 4000
        }
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
        memory_hard_limit = 1000
      }

      resources {
        cpu = 100
        memory = 300
        network {
          mbits = 1
          port "bbb-html5-back" {}
        }
      }

      service {
        name = "bbb-html5-back"
        port = "bbb-html5-back"
        tags = ["fabio-:${config.port_bbb_html5_back} proto=tcp"]
        check {
          name = "bbb-html5-back"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "freeswitch" {
      ${ task_logs() }
      leader = false

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

      env {
        DOMAIN = "bbb.${liquid_domain}"
        # TODO : PUBLIC IP MUST BE TAKEN FROM CONFIG
        # TODO : replace bbb_secret occurences by config-vars
        # TODO : move vol-fs into fs/vol ( volumes mappings )
        FS_BINDING_IP = "0.0.0.0"
        EXTERNAL_IPv4 = "185.34.32.199"
        INTERNAL_IPv4 = "127.0.0.1"
        #EXTERNAL_IPv6 = "\$\{EXTERNAL_IPv6:-::1}"
        SIP_IP_ALLOWLIST = "0.0.0.0/0"
        SOUNDS_LANGUAGE = "en-us-callie"
		RANGE_MIN_PORT = "16400"
		RANGE_MAX_PORT = "16500"
        ESL_PASSWORD = "bbb_secret"
        FREESWITCH_WS_ON = "yes"
        FREESWITCH_WSS_ON = "yes"
        FREESWITCH_WS_BIND = "0.0.0.0"
        FREESWITCH_WSS_BIND = "0.0.0.0"
      }

      template {
          destination = "local/start.sh"
          data = <<EOF
#!/bin/bash

#apt install -y iproute2
#ip addr add 185.34.32.199 dev lo

cp /opt/freeswitch/conf/vars.xml.tmpl /opt/freeswitch/conf/vars.xml
cp /opt/freeswitch/conf/autoload_configs/switch.conf.xml.tmpl /opt/freeswitch/conf/autoload_configs/switch.conf.xml
cp /local/freeswitch.sip.conf.external.xml /opt/freeswitch/conf/sip_profiles/external.xml

sed -i 's/ESL_PASSWORD/{{ env "ESL_PASSWORD" }}/' /opt/freeswitch/conf/vars.xml
#sed -i 's/SOUNDS_PATH/{{ env "SOUNDS_PATH" }}/' /opt/freeswitch/conf/vars.xml
sed -i 's/INTERNAL_IPV4/{{ env "INTERNAL_IPv4" }}/' /opt/freeswitch/conf/vars.xml
sed -i 's/FS_BINDING_IP/{{ env "FS_BINDING_IP" }}/' /opt/freeswitch/conf/vars.xml
sed -i 's/DOMAIN/{{ env "DOMAIN" }}/' /opt/freeswitch/conf/vars.xml
sed -i 's/EXTERNAL_IPV4/{{ env "EXTERNAL_IPv4" }}/' /opt/freeswitch/conf/vars.xml

sed -i 's/RANGE_MIN_PORT/{{ env "RANGE_MIN_PORT" }}/' /opt/freeswitch/conf/autoload_configs/switch.conf.xml
sed -i 's/RANGE_MAX_PORT/{{ env "RANGE_MAX_PORT" }}/' /opt/freeswitch/conf/autoload_configs/switch.conf.xml

sed -i 's/::/0.0.0.0/' /opt/freeswitch/etc/freeswitch/autoload_configs/event_socket.conf.xml

/entrypoint.sh
EOF
      }

      template {
        data = <<EOF
<profile name="external">
  <!-- http://wiki.freeswitch.org/wiki/Sofia_Configuration_Files -->
  <!-- This profile is only for outbound registrations to providers -->
  <gateways>
    <X-PRE-PROCESS cmd="include" data="external/*.xml"/>
  </gateways>

  <aliases>
    <!--
        <alias name="outbound"/>
        <alias name="nat"/>
    -->
  </aliases>

  <domains>
    <domain name="all" alias="false" parse="true"/>
  </domains>

  <settings>
    <param name="debug" value="0"/>
    <!-- If you want FreeSWITCH to shutdown if this profile fails to load, uncomment the next line. -->
    <!-- <param name="shutdown-on-fail" value="true"/> -->
    <param name="sip-trace" value="no"/>
    <param name="sip-capture" value="no"/>
    <param name="rfc2833-pt" value="101"/>
    <!-- RFC 5626 : Send reg-id and sip.instance -->
    <!--<param name="enable-rfc-5626" value="true"/> -->
    <param name="sip-port" value="{{ "$$" }}{external_sip_port}"/>
    <param name="dialplan" value="XML"/>
    <param name="context" value="public"/>
    <param name="dtmf-duration" value="2000"/>
    <param name="inbound-codec-prefs" value="{{ "$$" }}{global_codec_prefs}"/>
    <param name="outbound-codec-prefs" value="{{ "$$" }}{outbound_codec_prefs}"/>
    <param name="hold-music" value="{{ "$$" }}{hold_music}"/>
    <param name="rtp-timer-name" value="soft"/>
    <!--<param name="enable-100rel" value="true"/>-->
    <!--<param name="disable-srv503" value="true"/>-->
    <!-- This could be set to "passive" -->
    <param name="local-network-acl" value="localnet.auto"/>
    <param name="manage-presence" value="false"/>


    <!-- Added for Microsoft Edge browser -->
    <param name="apply-candidate-acl" value="localnet.auto"/>
    <param name="apply-candidate-acl" value="wan_v4.auto"/>
    <param name="apply-candidate-acl" value="rfc1918.auto"/>
    <param name="apply-candidate-acl" value="any_v4.auto"/>

    <!-- used to share presence info across sofia profiles
         manage-presence needs to be set to passive on this profile
         if you want it to behave as if it were the internal profile
         for presence.
    -->
    <!-- Name of the db to use for this profile -->
    <param name="dbname" value="sqlite://memory://file:external?mode=memory&amp;cache=shared"/>
    <!--<param name="presence-hosts" value="{{ "$$" }}{domain}"/>-->
    <!--<param name="force-register-domain" value="{{ "$$" }}{domain}"/>-->
    <!--all inbound reg will stored in the db using this domain -->
    <!--<param name="force-register-db-domain" value="{{ "$$" }}{domain}"/>-->
    <!-- ************************************************* -->

    <!--<param name="aggressive-nat-detection" value="true"/>-->
    <param name="inbound-codec-negotiation" value="generous"/>
    <param name="nonce-ttl" value="60"/>
    <param name="auth-calls" value="false"/>
    <param name="inbound-late-negotiation" value="true"/>
    <param name="inbound-zrtp-passthru" value="true"/> <!-- (also enables late negotiation) -->
    <!--
        DO NOT USE HOSTNAMES, ONLY IP ADDRESSES IN THESE SETTINGS!
    <param name="ext-rtp-ip" value="auto-nat"/>
    <param name="ext-sip-ip" value="auto-nat"/>
    -->

    <param name="rtp-ip" value="{{ "$$" }}{external_ip_v4}"/>
    <param name="sip-ip" value="{{ "$$" }}{external_ip_v4}"/>
    <param name="ext-rtp-ip" value="{{ "$$" }}{external_rtp_ip}"/>
    <param name="ext-sip-ip" value="{{ "$$" }}{external_sip_ip}"/>

    <!--
      Listen only clients somehow run into this timeout
      causing 
        Hangup sofia/external/GLOBAL_AUDIO_76116@10.7.7.1 [CS_EXECUTE] [MEDIA_TIMEOUT]
        [mcs-freeswitch] Dispatching conference new video floor event released 
        [mcs-freeswitch] Received CHANNEL_HANGUP for
    -->
    <param name="rtp-timeout-sec" value="86400"/>

    <param name="rtp-hold-timeout-sec" value="1800"/>
    <param name="enable-3pcc" value="proxy"/>

    <!-- TLS: disabled by default, set to "true" to enable -->
    <param name="tls" value="{{ "$$" }}{external_ssl_enable}"/>
    <!-- Set to true to not bind on the normal sip-port but only on the TLS port -->
    <param name="tls-only" value="false"/>
    <!-- additional bind parameters for TLS -->
    <param name="tls-bind-params" value="transport=tls"/>
    <!-- Port to listen on for TLS requests. (5081 will be used if unspecified) -->
    <param name="tls-sip-port" value="{{ "$$" }}{external_tls_port}"/>
    <!-- Location of the agent.pem and cafile.pem ssl certificates (needed for TLS server) -->
    <!--<param name="tls-cert-dir" value=""/>-->
    <!-- Optionally set the passphrase password used by openSSL to encrypt/decrypt TLS private key files -->
    <param name="tls-passphrase" value=""/>
    <!-- Verify the date on TLS certificates -->
    <param name="tls-verify-date" value="true"/>
    <!-- TLS verify policy, when registering/inviting gateways with other servers (outbound) or handling inbound registration/invite requests how should we verify their certificate -->
    <!-- set to 'in' to only verify incoming connections, 'out' to only verify outgoing connections, 'all' to verify all connections, also 'in_subjects', 'out_subjects' and 'all_subjects' for subject validation. Multiple policies can be split with a '|' pipe -->
    <param name="tls-verify-policy" value="none"/>
    <!-- Certificate max verify depth to use for validating peer TLS certificates when the verify policy is not none -->
    <param name="tls-verify-depth" value="2"/>
    <!-- If the tls-verify-policy is set to subjects_all or subjects_in this sets which subjects are allowed, multiple subjects can be split with a '|' pipe -->
    <param name="tls-verify-in-subjects" value=""/>
    <!-- TLS version ("sslv23" (default), "tlsv1"). NOTE: Phones may not work with TLSv1 -->
    <param name="tls-version" value="{{ "$$" }}{sip_tls_version}"/>
    {{ if env "FREESWITCH_WS_ON" }}
    <param name="ws-binding"  value="{{ env "FREESWITCH_WS_BIND" }}:5066"/>
    {{ end }}
    {{ if env "FREESWITCH_WSS_ON" }}
    <param name="wss-binding"  value="{{ env "FREESWITCH_WSS_BIND" }}:7443"/>
    {{ end }}
    

    <!-- enable rtcp on every channel also can be done per leg basis with rtcp_audio_interval_msec variable set to passthru to pass it across a call-->
    <param name="rtcp-audio-interval-msec" value="5000"/>
    <param name="rtcp-video-interval-msec" value="5000"/>

    <!-- Cut down in the join time -->
    <param name="dtmf-type" value="info"/>
    <param name="liberal-dtmf" value="true"/>
  </settings>
</profile>
        EOF
        destination = "local/freeswitch.sip.conf.external.xml"
      }

      config {
        image = "piaille/bbb-fs:1.0.12"
        entrypoint = ["/bin/bash", "/local/start.sh"]
        cap_add = [ "ipc_lock", "net_raw", "sys_nice", "sys_resource", "net_admin", "net_broadcast" ]
        #cap_add = [ "all" ]
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/vol-freeswitch:/var/freeswitch/meetings",
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/freeswitch/dialplan_public/:/etc/freeswitch/dialplan/public_docker/",
#          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/freeswitch/sip_profiles/:/etc/freeswitch/sip_profiles/external/",
        ]
        labels {
          liquid_task = "bbb-fs"
        }
        port_map {
            fsesl = "8021"
            ws = "5066"
            wss = "7443"
            sip = "5060"
            sipint = "5090"
        }
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
        memory_hard_limit = 1000
      }

      resources {
        cpu = 100
        memory = 300
        network {
          mbits = 1
            port "fsesl" {
            }
            port "ws" {
            }
            port "wss" {
            }
            port "sip" {
            }
            port "sipint" {
            }
        }
      }

      service {
        name = "bbb-fs"
        port = "fsesl"
        tags = [
            "fabio-:${config.port_bbb_fsesl} proto=tcp",
            "fabio-:${config.port_bbb_ws} proto=tcp",
            "fabio-:${config.port_bbb_wss} proto=tcp",
            "fabio-:${config.port_bbb_sip} proto=tcp",
            "fabio-:${config.port_bbb_sipint} proto=tcp"
            ]
        check {
          name = "bbb-fs"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "kurento" {
      ${ task_logs() }
      leader = false

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

      env {
        DOMAIN = "bbb.${liquid_domain}"
      }
      template {
          destination = "local/start.sh"
          data = <<-EOF
#!/bin/bash
cp /local/BaseRtpEndpoint.conf.ini /etc/kurento/modules/kurento/BaseRtpEndpoint.conf.ini
cp /local/WebRtcEndpoint.conf.ini /etc/kurento/modules/kurento/WebRtcEndpoint.conf.ini

/entrypoint.sh
          EOF
          }

      template {
          destination = "local/BaseRtpEndpoint.conf.ini"
          env = true
          data = <<-EOF
minPort=${config.port_bbb_kurento_min}
maxPort=${config.port_bbb_kurento_max}
          EOF
          }

      template {
          destination = "local/WebRtcEndpoint.conf.ini"
          env = true
          data = <<-EOF
externalIPv4=185.34.32.199
          EOF
          }

      config {
        image = "kurento/kurento-media-server:6.18"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/kurento:/var/kurento",
        ]
        labels {
          liquid_task = "bbb-kurento"
        }
        port_map {
            kurento = 8888
        }

        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
        memory_hard_limit = 1000
        entrypoint = ["/bin/bash", "/local/start.sh"]
      }

      resources {
        cpu = 100
        memory = 300
        network {
          mbits = 1
          port "kurento" {}
        }
      }

      service {
        name = "bbb-kurento"
        port = "kurento"
        tags = ["fabio-:${config.port_bbb_kurento} proto=tcp"]
        check {
          name = "bbb-kurento"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "bbb-sfu" {
      ${ task_logs() }
      leader = false

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

      env {
        DOMAIN = "bbb.${liquid_domain}"
        CLIENT_HOST = "0.0.0.0"
        CLIENT_PORT = "3008"
        REDIS_HOST = "{% raw %}${attr.unique.network.ip-address}{% endraw %}"
        REDIS_PORT = "${config.port_bbb_redis}"
        FREESWITCH_IP = "{% raw %}${attr.unique.network.ip-address}{% endraw %}"
        FREESWITCH_SIP_IP = "185.34.32.199"
        FREESWITCH_CONN_IP = "185.34.32.199"
        #REC_MIN_PORT = "16800"
        #REC_MAX_PORT = "16900"
        MS_RTC_MIN = "16800"
        MS_RTC_MAX = "16900"
        MCS_HOST = "0.0.0.0"
        MCS_ADDRESS = "127.0.0.1"
        EXTERNAL_IPv4 = "185.34.32.199"
        #MS_WEBRTC_LISTEN_IPS = "[{'ip':'0.0.0.0', 'announcedIp':'185.34.32.199'}]"
        #MS_WEBRTC_LISTEN_IPS = "[{'ip':'0.0.0.0', 'announcedIp':'${EXTERNAL_IPv4}'}]"
        ESL_IP = "{% raw %}${attr.unique.network.ip-address}{% endraw %}"
        ESL_PASSWORD = "bbb_secret"
        MS_WEBRTC_LISTEN_IPS = "[{\"ip\":\"0.0.0.0\", \"announcedIp\":\"185.34.32.199\"}]"
        MS_RTP_LISTEN_IP = "{\"ip\":\"0.0.0.0\", \"announcedIp\":\"185.34.32.199\"}"
        KURENTO = "{\"ip\":\"0.0.0.0\", \"url\":\"ws://10.66.60.1:${config.port_bbb_kurento}/kurento\"}"
      }

      config {
        image = "piaille/bbb-sfu:1.0.1"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/sfu/mediasoup:/var/mediasoup/",
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/sfu/log:/var/log/bbb-webrtc-sfu/",
        ]
        port_map {
          sfu = 3008
        }
        labels {
          liquid_task = "bbb-sfu"
        }
        # 128MB, the default postgresql shared_memory config
        shm_size = 134217728
        memory_hard_limit = 1000
      }

      resources {
        cpu = 100
        memory = 300
        network {
          mode = "host"
          mbits = 1
          port "sfu" {
              }
        }
      }

      service {
        name = "bbb-sfu"
        port = "sfu"
        tags = ["fabio-:${config.port_bbb_sfu} proto=tcp"]
        check {
          name = "bbb-sfu"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "nginx" {

      ${ task_logs() }
      leader = false

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
        image = "nginx:1.25.3"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/nginx/bbb_conf/:/etc/nginx/bbb_conf_template/",
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/nginx/main_conf/:/bbb/",
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/nginx/default_pdf/default.pdf:/www/default.pdf",
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/html5/static/:/html5-static",
        ]
        entrypoint = ["/bin/sh", "/local/start.sh"]
        port_map {
          bbb-nginx = 9959
        }
        labels {
          liquid_task = "bbb_web"
        }
        memory_hard_limit = 2000
      }

      env {
        FREESWITCH_SCHEME = "https"
        FREESWITCH_WS_PORT = "7443"
        FREESWITCH_EXTERNAL_IP = "185.34.32.199"
          }

      template {
        data = <<-EOF
#!/bin/sh

cp -ra /etc/nginx/bbb_conf_template /etc/nginx/bbb
sed -i 's/NOMAD_BBB_WEB_IP/10.66.60.1/' /etc/nginx/bbb/web.nginx
sed -i 's/NOMAD_BBB_WEB_PORT/${config.port_bbb_web}/' /etc/nginx/bbb/web.nginx
sed -i 's/NOMAD_BBB_SFU_IP/10.66.60.1/' /etc/nginx/bbb/webrtc-sfu.nginx
sed -i 's/NOMAD_BBB_SFU_PORT/${config.port_bbb_sfu}/' /etc/nginx/bbb/webrtc-sfu.nginx
sed -i 's/NOMAD_FREESWITCH_WS_PORT/{{ env "FREESWITCH_WS_PORT" }}/' /etc/nginx/bbb/sip.nginx
sed -i 's/NOMAD_FREESWITCH_SCHEME/{{ env "FREESWITCH_SCHEME" }}/' /etc/nginx/bbb/sip.nginx

cp /bbb/bigbluebutton.conf.template /bbb/bigbluebutton.conf

sed -i 's/NOMAD_GREENLIGHT_IP/10.66.60.1/' /bbb/bigbluebutton.conf
sed -i 's/NOMAD_GREENLIGHT_PORT/${config.port_bbb_gl}/' /bbb/bigbluebutton.conf
sed -i 's/NOMAD_BBB_HTML5_FRONT_IP/10.66.60.1/' /bbb/bigbluebutton.conf
sed -i 's/NOMAD_BBB_HTML5_FRONT_PORT/${config.port_bbb_html5_front}/' /bbb/bigbluebutton.conf
sed -i 's/NOMAD_NGINX_LISTEN_PORT/${config.port_bbb_nginx}/' /bbb/bigbluebutton.conf
sed -i 's/NOMAD_EXTERNAL_FREESWITCH/{{ env "FREESWITCH_EXTERNAL_IP" }}/' /bbb/bigbluebutton.conf

cat /bbb/bigbluebutton.conf

cp /bbb/bigbluebutton.conf /etc/nginx/conf.d/default.conf
mkdir /www

#/docker-entrypoint.sh
nginx-debug -g "daemon off;"
EOF
        destination = "local/start.sh"
      }

      resources {
        memory = 450
        cpu = 150
        network {
          mbits = 1
          port "bbb-nginx" {}
        }
      }

/*
      service {
        name = "bbb-nginx"
        port = "bbb-nginx"
        tags = ["fabio-:${config.port_bbb_nginx} proto=tcp"]
        check {
          name = "bbb-nginx"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
      */
      service {
        name = "bbb-nginx"
        port = "bbb-nginx"
        tags = [
          "traefik.enable=true",
          "traefik.frontend.rule=Host:bbb.${liquid_domain}",
          "fabio-:${config.port_bbb_nginx} proto=tcp",
        ]
        check {
          name = "http"
          initial_status = "critical"
          type = "http"
          path = "/"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }

    task "greenlight" {
      ${ task_logs() }
      leader = false

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

      env {
        DATABASE_URL = "postgres://greenlight:postgres_secret@{% raw %}${attr.unique.network.ip-address}{% endraw %}:${config.port_bbb_pg}/greenlight_production"
        REDIS_URL = "redis://{% raw %}${attr.unique.network.ip-address}{% endraw %}:${config.port_bbb_redis}"
        BIGBLUEBUTTON_ENDPOINT = "https://bbb.${liquid_domain}/bigbluebutton/api"
        BIGBLUEBUTTON_SECRET = "bbb_secret"
        SECRET_KEY_BASE = "mybigsecretkeybase_secret"
        RELATIVE_URL_ROOT = "/"
      }

      config {
        image = "bigbluebutton/greenlight:latest"
        volumes = [
          "{% raw %}${meta.liquid_volumes}{% endraw %}/bbb/greenlight/data/:/usr/src/app/storage/",
        ]
        port_map {
          bbb-gl = 3000
        }
        labels {
          liquid_task = "bbb_greenlight"
        }
        memory_hard_limit = 2000
      }

      resources {
        memory = 450
        cpu = 150
        network {
          mbits = 1
          port "bbb-gl" {}
        }
      }

      service {
        name = "bbb-gl"
        port = "bbb-gl"
        tags = ["fabio-:${config.port_bbb_gl} proto=tcp"]
        check {
          name = "bbb-gl"
          initial_status = "critical"
          type = "tcp"
          interval = "${check_interval}"
          timeout = "${check_timeout}"
        }
      }
    }
  }
}
