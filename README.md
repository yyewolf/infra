# Personnal Infrastructure

This repository represents the state of my personnal infrastructure, it'll also document how to repeat it.

## Bootstrap

### GPG

You will need to generate a GPG key for your cluster, this is so you can put secrets in a public repo without them being redable by anyone else (using SOPS).  
Here is how to generate one :

```bash
$ gpg --expert --full-generate-key
```

In my case I used ECC and ECC (9) without expiration to avoid struggle later on.

### SSH

You will also need to generate an SSH key to access your cluster.  
You can do so using :

```bash
$ ssh-keygen -t ed25519
```

### Terraform

Once that's done, you can easily bootup everything with these two :

```bash
$ terraform plan
$ terraform apply
```
