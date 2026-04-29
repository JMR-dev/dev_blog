data "vultr_os" "alma" {
  filter {
    name   = "name"
    values = [var.os_name_filter]
  }
}

resource "vultr_instance" "blog" {
  region      = var.region
  plan        = var.plan
  os_id       = data.vultr_os.alma.id
  hostname    = var.hostname
  label       = var.hostname
  tags        = var.tags
  ssh_key_ids = var.ssh_key_ids

  backups = "enabled"
  backups_schedule {
    type = "daily"
    hour = var.backup_hour_utc
  }

  enable_ipv6      = true
  ddos_protection  = false
  activation_email = false
}

# ---------------------------------------------------------------------------
# Static (Reserved) IPs
#
# Reserved IPs survive instance replacement, so DNS records stay valid even
# if `vultr_instance.blog` is destroyed and recreated.
#
# - v4 reservation is a single /32, so `subnet` is the address itself.
# - v6 reservation is a /64; `subnet` is the network prefix and the instance
#   takes an address inside it (exposed as `vultr_instance.blog.v6_main_ip`).
# ---------------------------------------------------------------------------

resource "vultr_reserved_ip" "v4" {
  region      = var.region
  ip_type     = "v4"
  label       = "${var.hostname}-v4"
  instance_id = vultr_instance.blog.id
}

resource "vultr_reserved_ip" "v6" {
  region      = var.region
  ip_type     = "v6"
  label       = "${var.hostname}-v6"
  instance_id = vultr_instance.blog.id
}
