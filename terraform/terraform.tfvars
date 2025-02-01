public_key_pair_path = "./files/keys/ssh.pub"
private_key_pair_path = "./files/keys/ssh"

network_external_id = "34a684b8-2889-4950-b08e-c33b3954a307" # This is the floating ip network id on openstack
network_dns_servers = [ "1.1.1.1", "9.9.9.9" ] 
openstack_auth_url = "https://api.pub1.infomaniak.cloud/identity/v3"

ssh_login_name = "debian"
network_floating_ip_pool = "ext-floating1"

control_plane_image_id = "Debian 12 bookworm"
control_plane_flavor_id = "a2-ram4-disk20-perf1"
control_plane_number = "1"

worker_image_id = "Debian 12 bookworm"
worker_flavor_id = "a4-ram8-disk20-perf1"
worker_number = "3"

repository_url = "https://github.com/yyewolf/infra"