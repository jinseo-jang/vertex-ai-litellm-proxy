with open('terraform_litellm/main.tf', 'r') as f:
    content = f.read()

content = content.replace('address      = "192.168.255.250"', 'address      = "192.168.255.240"')

with open('terraform_litellm/main.tf', 'w') as f:
    f.write(content)
