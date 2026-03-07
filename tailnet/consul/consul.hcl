datacenter = "cloudnet"
data_dir   = "/consul/data"
client_addr = "0.0.0.0"

ui_config {
  enabled = true
}

server = true
bootstrap_expect = 1

telemetry {
  prometheus_retention_time = "10s"
  disable_hostname = true
}
