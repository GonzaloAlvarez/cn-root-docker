datacenter = "cloudnet"
data_dir   = "/consul/data"
client_addr    = "0.0.0.0"
advertise_addr = "127.0.0.1"

ui_config {
  enabled = true
}

server = true
bootstrap_expect = 1

telemetry {
  prometheus_retention_time = "10s"
  disable_hostname = true
}
