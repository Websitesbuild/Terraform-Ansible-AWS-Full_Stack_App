resource "aws_security_group" "VM_SGs" {
  name        = "VM_SGs"
  description = "Allow HTTP and TCP"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "amit_key" {
  key_name   = "amit-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_instance" "VM" {
  ami                    = var.AMI
  instance_type          = var.TYPE
  count                  = var.COUNT
  key_name               = aws_key_pair.amit_key.key_name
  vpc_security_group_ids = [aws_security_group.VM_SGs.id]

  tags = {
    Name = "VM-${count.index}"
  }

  user_data = <<-EOF
#!/bin/bash

# Create user
adduser amituser --disabled-password --gecos ""
echo "amituser:amituser" | chpasswd

# Give sudo access safely
echo "amituser ALL=(ALL) NOPASSWD:ALL" | tee /etc/sudoers.d/amituser

# Enable password authentication safely
sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/60-cloudimg-settings.conf

systemctl restart ssh

# Setup SSH
mkdir -p /home/amituser/.ssh
chmod 700 /home/amituser/.ssh

echo "${file("~/.ssh/id_rsa.pub")}" >> /home/amituser/.ssh/authorized_keys

chmod 600 /home/amituser/.ssh/authorized_keys
chown -R amituser:amituser /home/amituser/.ssh
EOF
}

resource "null_resource" "generate_inventory" {

  depends_on = [aws_instance.VM]

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
    sudo sed -i '/\\[webservers\\]/,/^$/d' /etc/ansible/hosts

    sudo bash -c 'echo "[webservers]" >> /etc/ansible/hosts'

    %{ for ip in aws_instance.VM[*].public_ip ~}
    sudo bash -c 'echo "${ip} ansible_user=amituser ansible_ssh_private_key_file=~/.ssh/id_rsa" >> /etc/ansible/hosts'
    %{ endfor ~}
    EOT
  }
}

resource "null_resource" "run_ansible" {

  depends_on = [
    aws_instance.VM,
    null_resource.generate_inventory
  ]

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
    for ip in ${join(" ", aws_instance.VM[*].public_ip)}; do
      echo "Waiting for $ip..."
      while ! nc -z $ip 22; do
        sleep 60
      done
    done

    ansible-playbook -i /etc/ansible/hosts deploy_nginx_react_local.yml
    EOT
  }
}