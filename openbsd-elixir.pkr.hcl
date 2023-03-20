packer {
  required_version = ">= 1.8.0"
  required_plugins {
    vmware = {
      version = "= 1.0.7"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "packer-boot-wait" {
  type    = string
  default = "25"
}
variable "packer-ssh-host" {
  type    = string
  default = "openbsd-elixir"
}
variable "packer-vnc-port" {
  type    = string
  default = "5987"
}
variable "use-openbsd-snapshot" {
  type    = bool
  default = "false"
}
variable "openbsd-install-img" {
  type    = string
  default = "install72.img"
}
variable "openbsd-hostname" {
  type    = string
  default = "openbsd-elixir"
}
variable "openbsd-username" {
  type    = string
  default = "user"
}
variable "openbsd-excluded-sets" {
  type    = string
  default = "-g* -x*"
}
variable "rc-firsttime-wait" {
  type    = string
  default = "60"
}

# Elixir environment variables
variable "elixir-env-vars" {
  type = list(string)
  default = [
    "MIX_ENV=prod",
    "LANG=en_US.UTF-8",
    "LC_ALL=en_US.UTF-8",
    "SECRET_KEY_BASE=12345678901234567890123456789012345678901234567890123456789012345",
    "DATABASE_URL=ecto://postgres@localhost/hello_prod",
  ]
}

source "vmware-iso" "openbsd-elixir" {
  version              = "20"
  iso_url              = "./empty.iso"
  iso_checksum         = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  ssh_username         = "user"
  ssh_password         = "user"
  vnc_port_min         = "${var.packer-vnc-port}"
  vnc_port_max         = "${var.packer-vnc-port}"
  vnc_disable_password = "true"
  shutdown_command     = "doas /sbin/shutdown -p now"
  keep_registered      = "false"
  skip_export          = "false"
  headless             = "true"
  format               = "vmx"
  cpus                 = "8"
  memory               = "4096"
  disk_adapter_type    = "nvme"
  disk_size            = "65535"
  disk_type_id         = "0"
  network_adapter_type = "e1000e"
  usb                  = "true"
  guest_os_type        = "arm-other-64"
  vmx_data = {
    # Nothing is working without EFI!!! ;-)
    "firmware"     = "efi"
    "architecture" = "arm-other-64"
    # We need the USB stuff for packer to type text.
    "usb_xhci.present" = "TRUE"
    # We have to add the vmdk converted OpenBSD install image file,
    "nvme0.present"    = "TRUE"
    "nvme0:1.fileName" = "${var.openbsd-install-img}"
    "nvme0:1.present"  = "TRUE"
    # and make sure to boot from it.
    "bios.bootOrder" = "HDD"
    "bios.hddOrder"  = "nvme0:1"
  }
  boot_wait = "${var.packer-boot-wait}s"
  boot_command = [
    "install<return><wait2s>",
    "us<return><wait2s>",
    "${var.openbsd-hostname}<return><wait2s>",
    "<return><wait2s>",
    "autoconf<return><wait5s>",
    "none<return><wait2s>",
    "done<return><wait2s>",
    "root<return><wait2s>",
    "root<return><wait2s>",
    "yes<return><wait2s>",
    "${var.openbsd-username}<return><wait2s>",
    "${var.openbsd-username}<return><wait2s>",
    "${var.openbsd-username}<return><wait2s>",
    "${var.openbsd-username}<return><wait2s>",
    "no<return><wait2s>",
    "<return><wait2s>",
    "?<return><wait2s>",
    "sd0<return><wait2s>",
    "whole<return><wait2s>",
    "a<return><wait5s>",
    "done<return><wait5s>",
    "disk<return><wait2s>",
    "no<return><wait2s>",
    "sd1<return><wait2s>",
    "a<return><wait2s>",
    "<return><wait2s>",
    "${var.openbsd-excluded-sets}<return><wait2s>",
    "done<return><wait2s>",
    "yes<return><wait30s>",
    "<return><wait2s>",
    "<return><wait30s>",
    "reboot<return><wait${var.rc-firsttime-wait}s>",
    "root<return><wait2s>",
    "root<return><wait3s>",
    "cp /etc/examples/doas.conf /etc/<return><wait2s>",
    # For an easier system update we allow the :wheel user to access all command without password.
    # We will restrict this in the last builder step again.
    "echo 'permit nopass :wheel as root' >> /etc/doas.conf<return><wait2s>",
    "exit<return><wait2s>",
  ]
}

build {
  sources = ["sources.vmware-iso.openbsd-elixir"]
  # Upgrade the system to the latest patch level
  provisioner "shell" {
    expect_disconnect = "true"
    inline = concat(
      # Only execute the syspatch if we are not using the OpenBSD snapshot.
      [for command in ["doas syspatch"] : command if !var.use-openbsd-snapshot],
      ["doas shutdown -r now"]
    )
  }
  # Install required packages and configure/bring up postgresql
  provisioner "shell" {
    pause_before     = "10s"
    inline = [
      # https://developer.hashicorp.com/terraform/language/expressions/conditionals
      "doas pkg_add -D snapshot elixir postgresql-server curl",
      "cd /var/postgresql/ && doas su _postgresql -c \"initdb --pgdata=/var/postgresql/data/ --username=postgres --encoding=UTF-8 --locale=en_US.UTF-8\"",
      "doas rcctl enable postgresql && doas rcctl start postgresql",
    ]
  }
  # Preparing and building the elixir/phoenix environment
  provisioner "shell" {
    environment_vars = "${var.elixir-env-vars}"
    inline = [
      "mix local.hex --force",
      "mix local.rebar --force",
      "mix archive.install --force hex phx_new",
      "echo yes | mix phx.new hello",
      "cd $HOME/hello && mix compile && mix ecto.create && mix phx.digest && tmux new-session -d -s openbsd-elixir 'mix phx.server'",
      "sleep 10",
      "curl --silent http://localhost:4000 | grep 'Peace of mind from prototype to production.'",
    ]
  }
  # After finishing the setup we copy the system log locally.
  provisioner "file" {
    direction   = "download"
    source      = "/var/log/messages"
    destination = "./log/"
  }
  # After finishing the setup we copy the daemon log locally.
  provisioner "file" {
    direction   = "download"
    source      = "/var/log/daemon"
    destination = "./log/"
  }
  # We have to make sure that the doas rights of the user are restricted again.
  provisioner "shell" {
    inline = [
      "doas sed -i 's|permit nopass :wheel as root|permit nopass :wheel as root cmd /sbin/shutdown|g' /etc/doas.conf"
    ]
  }
}
