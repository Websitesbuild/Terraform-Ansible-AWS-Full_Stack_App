output "public_ips" {
  value = aws_instance.VM[*].public_ip
}