packer {
  required_plugins {
    tart = {
      version = ">= 1.14.0"
      source  = "github.com/cirruslabs/tart"
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
  sources = ["source.tart-cli.ubuntu"]

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
      "cat > /etc/sudoers.d/agent <<'SUDOERS'\nagent ALL=(ALL) NOPASSWD: /usr/bin/systemctl start *\nagent ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop *\nagent ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart *\nagent ALL=(ALL) NOPASSWD: /usr/bin/systemctl status *\nagent ALL=(ALL) NOPASSWD: /usr/sbin/service *\nagent ALL=(ALL) NOPASSWD: /usr/bin/apt-get *\nagent ALL=(ALL) NOPASSWD: /usr/bin/apt *\nagent ALL=(ALL) NOPASSWD: /usr/bin/dpkg *\nagent ALL=(ALL) NOPASSWD: /usr/bin/mysql *\nagent ALL=(ALL) NOPASSWD: /usr/bin/redis-cli *\nagent ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/hosts\nagent ALL=(ALL) NOPASSWD: /usr/bin/chmod *\nagent ALL=(ALL) NOPASSWD: /usr/bin/chown *\nSUDOERS",
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
}
