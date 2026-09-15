packer {
  required_plugins {
    tart = {
      version = ">= 1.14.0"
      source  = "github.com/cirruslabs/tart"
    }
    googlecompute = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

variable "vm_name" {
  type    = string
  default = "fxa-dev-base"
}

variable "cpu_count" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 8192
}

variable "disk_size_gb" {
  type    = number
  default = 50
}

# GCE: same scripts, stock arm64 Ubuntu, built over IAP with no external IP.
# N4A and C4A need Hyperdisk; the plugin's pd-standard default fails the build.
variable "project" {
  type    = string
  default = ""
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

source "googlecompute" "ubuntu" {
  project_id          = var.project
  zone                = var.zone
  machine_type        = "c4a-highcpu-4"
  source_image_family = "ubuntu-2404-lts-arm64"
  disk_type           = "hyperdisk-balanced"
  disk_size           = var.disk_size_gb
  # Unique name, stable family: a rebuild never collides with the image the
  # runners boot from, and vm_clone picks the newest in the family.
  image_name          = "${var.vm_name}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  image_family        = var.vm_name
  ssh_username        = "packer"
  network             = "fxa-sandbox"
  subnetwork          = "fxa-sandbox"
  omit_external_ip    = true
  use_internal_ip     = true
  use_iap             = true
}

source "tart-cli" "ubuntu" {
  vm_base_name   = "ghcr.io/cirruslabs/ubuntu:latest"
  vm_name        = "${var.vm_name}"
  cpu_count      = var.cpu_count
  memory_gb      = var.memory_mb / 1024
  disk_size_gb   = var.disk_size_gb
  ssh_username   = "admin"
  ssh_password   = "admin"
  ssh_timeout    = "120s"
}

build {
  sources = ["source.tart-cli.ubuntu", "source.googlecompute.ubuntu"]

  # Run provisioning scripts in order
  provisioner "shell" {
    script            = "${path.root}/scripts/01-base.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/02-node.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/03-infra.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/04-claude.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/04b-codex.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/05-proxy.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/06-agent-init.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/08-playwright.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/09-fxa-services.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  # Stage the canonical agent guide so 10-agent-guide.sh can install it
  # without duplicating the content. Single source of truth lives in
  # VM_AGENT_GUIDE.md at the repo root.
  provisioner "file" {
    source      = "${path.root}/../VM_AGENT_GUIDE.md"
    destination = "/tmp/vm-agent-guide.md"
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/10-agent-guide.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    script            = "${path.root}/scripts/07-cleanup.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  # Create the 'agent' user with restricted sudo
  provisioner "shell" {
    execute_command = "sudo bash -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      # UID 501 matches macOS default user — VirtioFS maps ownership by UID,
      # so the agent can read/write host-mounted files under /workspace.
      "useradd -m -s /bin/bash -u 501 agent",
      "passwd -l agent",
      # Restricted sudo: only specific service/package management commands
      "cat > /etc/sudoers.d/agent <<'SUDOERS'\nCmnd_Alias FXA_UNITS = /usr/bin/systemctl start mysql, /usr/bin/systemctl stop mysql, /usr/bin/systemctl restart mysql, /usr/bin/systemctl status mysql, /usr/bin/systemctl start redis-server, /usr/bin/systemctl stop redis-server, /usr/bin/systemctl restart redis-server, /usr/bin/systemctl status redis-server, /usr/bin/systemctl start firestore-emulator, /usr/bin/systemctl stop firestore-emulator, /usr/bin/systemctl restart firestore-emulator, /usr/bin/systemctl status firestore-emulator, /usr/bin/systemctl start goaws, /usr/bin/systemctl stop goaws, /usr/bin/systemctl restart goaws, /usr/bin/systemctl status goaws\nagent ALL=(ALL) NOPASSWD: FXA_UNITS\nagent ALL=(ALL) NOPASSWD: /usr/bin/mysql *\nagent ALL=(ALL) NOPASSWD: /usr/bin/redis-cli *\nagent ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/hosts\nSUDOERS",
      "chmod 440 /etc/sudoers.d/agent",
      "mkdir -p /home/agent/.ssh /home/agent/.config/claude /home/agent/.claude",
      # screen config: scrollback, status bar, native scroll
      "cat > /home/agent/.screenrc <<'SCREENRC'\ndefscrollback 10000\nstartup_message off\ntermcapinfo xterm* ti@:te@\nhardstatus alwayslastline '%%{= bW} FxA Sandbox VM %%= scroll: Ctrl-a [  detach: Ctrl-a d '\nSCREENRC",
      "chown -R agent:agent /home/agent",
      "chmod 700 /home/agent/.ssh",
      # Lock the admin user's password (base image default creds)
      "passwd -l admin 2>/dev/null || true",
    ]
  }

  # GCE only: no host mount, so the tree and node_modules are baked in, and a
  # boot unit checks out the run's branch from instance metadata.
  provisioner "shell" {
    only              = ["googlecompute.ubuntu"]
    script            = "${path.root}/scripts/11-gce-clone.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }

  provisioner "shell" {
    only              = ["googlecompute.ubuntu"]
    script            = "${path.root}/scripts/12-gce-startup.sh"
    execute_command   = "sudo bash -c '{{ .Path }}'"
    expect_disconnect = false
  }
}
