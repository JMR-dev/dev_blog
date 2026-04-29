output "instance_id" {
  value = vultr_instance.blog.id
}

# Static IPv4 (Vultr Reserved IP /32).
output "main_ip" {
  value = vultr_reserved_ip.v4.subnet
}

# Static IPv6 prefix (Vultr Reserved IP /64). Use a host address inside this
# subnet for AAAA records (the instance's primary v6 is `ipv6_address`).
output "ipv6_subnet" {
  value = "${vultr_reserved_ip.v6.subnet}/${vultr_reserved_ip.v6.subnet_size}"
}

output "ipv6_address" {
  value = vultr_instance.blog.v6_main_ip
}

output "default_password" {
  value     = vultr_instance.blog.default_password
  sensitive = true
}

output "os" {
  value = data.vultr_os.alma.name
}
