with open('main.tf', 'r') as f:
    content = f.read()

content = content.replace('address      = "10.0.0.5"', 'address      = "192.168.255.250"')

with open('main.tf', 'w') as f:
    f.write(content)
