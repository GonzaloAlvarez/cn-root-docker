#!/bin/sh
# devbox-exporter: poll headscale (via the docker socket) for tag:devbox
# nodes and expose their online state as Prometheus metrics on :9101
# (inside ts-infra's netns; scraped by the sibling prometheus at
# 127.0.0.1:9101). Feeds the `devclouds` Grafana dashboard.
#
# online=1  -> devbox EC2 instance is running ("in use")
# online=0  -> instance stopped (clouddevbox stop / autostop)
# absent    -> destroyed (clouddevbox destroy removes the headscale node)
set -u

# apk at container start races cold-boot networking (known amun-docker
# gotcha) - retry until the repos are reachable.
until apk add --no-cache jq busybox-extras >/dev/null 2>&1; do
    echo "[devbox-exporter] apk add failed (network not ready?); retrying in 5s"
    sleep 5
done

mkdir -p /www
: > /www/metrics

JQ_PROG='
  (if type == "object" then (.nodes // .machines // []) else . end)
  | map(select(((.forcedTags // .forced_tags // []) | index("tag:devbox")) != null))
  | .[]
  | ((.givenName // .given_name // .name // "unknown") | sub("^devbox-"; "")) as $n
  | "devbox_online{devbox=\"\($n)\"} \(if .online then 1 else 0 end)",
    "devbox_last_seen_timestamp_seconds{devbox=\"\($n)\"} \((.lastSeen // .last_seen // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch 0))"
'

poll() {
    while true; do
        JSON="$(docker exec cloudnet-headscale-1 headscale nodes list -o json 2>/dev/null)" || JSON=""
        {
            echo "# HELP devbox_online devbox tailnet node online (1=in use) / offline (0=stopped)"
            echo "# TYPE devbox_online gauge"
            echo "# HELP devbox_last_seen_timestamp_seconds unix time headscale last saw the node"
            echo "# TYPE devbox_last_seen_timestamp_seconds gauge"
            echo "# HELP devbox_exporter_scrape_ok headscale poll succeeded"
            echo "# TYPE devbox_exporter_scrape_ok gauge"
            if [ -n "$JSON" ]; then
                echo "$JSON" | jq -r "$JQ_PROG" 2>/dev/null || true
                echo "devbox_exporter_scrape_ok 1"
            else
                echo "devbox_exporter_scrape_ok 0"
            fi
        } > /www/metrics.new && mv /www/metrics.new /www/metrics
        sleep 30
    done
}

poll &
echo "[devbox-exporter] serving :9101/metrics"
exec busybox-extras httpd -f -p 9101 -h /www
