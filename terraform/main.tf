terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  zone                     = "ru-central1-b"
  service_account_key_file = var.service_account_key_file
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
}

variable "vms" {
  type    = list(string)
  default = ["nginx1", "nginx2", "haproxy", "prometheus"]
}

resource "yandex_compute_instance" "vm" {

  allow_stopping_for_update = true
  platform_id               = "standard-v3"
  zone                      = "ru-central1-b"
  for_each = toset(var.vms)
  name     = each.value

  resources {
    cores         = 2
    memory        = 1
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = var.image_id
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet.id
    nat       = true
  }

  metadata = {
    user-data = "${file("~/meta.txt")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

resource "yandex_vpc_network" "network" {
  name = "network"
}

resource "yandex_vpc_subnet" "subnet" {
  name           = "subnet"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

output "internal_ip" {
  value = {
    for vm in yandex_compute_instance.vm:
    vm.name => vm.network_interface.0.ip_address
  }
}

output "external_ip" {
  value = {
    for vm in yandex_compute_instance.vm:
    vm.name => vm.network_interface.0.nat_ip_address
  }
}

locals {
  nginx_nat = [ for vm in yandex_compute_instance.vm: vm.network_interface.0.nat_ip_address if can(regex("nginx\\d", vm.name)) ]
  nginx     = [ for vm in yandex_compute_instance.vm: vm.network_interface.0.ip_address if can(regex("nginx\\d", vm.name)) ]
}

output "nginx_nat" {
  value = local.nginx_nat
}

output "nginx" {
  value = local.nginx
}

resource "local_file" "inventory" {
  content = templatefile("inventory.tmpl",
    {
      nginx      = local.nginx_nat
      haproxy    = yandex_compute_instance.vm[ "haproxy" ].network_interface.0.nat_ip_address
      prometheus = yandex_compute_instance.vm[ "prometheus" ].network_interface.0.nat_ip_address
    }
  )
  filename = "../ansible/inventory"
}

resource "local_file" "haproxy" {
  content = templatefile("haproxy.cfg.tmpl",
    {
      nginx      = local.nginx
    }
  )
  filename = "../ansible/roles/haproxy/files/haproxy.cfg"
}

resource "local_file" "prometheus" {
  content = templatefile("prometheus.yml.tmpl",
    {
      nginx      = local.nginx
      haproxy    = yandex_compute_instance.vm[ "haproxy" ].network_interface.0.ip_address
    }
  )
  filename = "../ansible/roles/prometheus/files/prometheus.yml"
}
