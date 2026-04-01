with open('terraform_litellm/main.tf', 'r') as f:
    content = f.read()

content = content.replace('address      = "10.255.255.254"', 'address      = "10.0.0.5"')

with open('terraform_litellm/main.tf', 'w') as f:
    f.write(content)
