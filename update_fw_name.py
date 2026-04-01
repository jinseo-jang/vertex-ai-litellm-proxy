with open('terraform_litellm/main.tf', 'r') as f:
    content = f.read()

content = content.replace('name                  = "google-api-psc-rule-tf"', 'name                  = "pscgoogleapistf"')

with open('terraform_litellm/main.tf', 'w') as f:
    f.write(content)
