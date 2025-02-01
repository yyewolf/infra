resource "openstack_networking_floatingip_v2" "this" {
  pool = var.network.floating_ip_pool
}

resource "openstack_compute_instance_v2" "this" {
  name            = var.name
  image_name      = var.image_id
  flavor_name     = var.flavor_id
  key_pair        = var.public_key_pair
  security_groups = var.security_groups

  network {
    name = var.network.name
  }

  user_data = var.user_data
}

resource "openstack_compute_floatingip_associate_v2" "this" {
  floating_ip = openstack_networking_floatingip_v2.this.address
  instance_id = openstack_compute_instance_v2.this.id
  fixed_ip    = openstack_compute_instance_v2.this.network.0.fixed_ip_v4
}

# We wait until the cloud init script is done, this is to ensure a fonctional kluster
resource "null_resource" "this" {
  connection {
    type     = "ssh"
    user     = var.ssh_login_name
    private_key = file(var.private_key_pair)
    host     = openstack_compute_floatingip_associate_v2.this.floating_ip
  }

  provisioner "remote-exec" {
    inline = [
      "while [ ! -f /tmp/signal ] && [ ${var.user_data != "" ? "1" : "2"} -eq 1 ]; do sleep 2; done",
    ]
  }
}