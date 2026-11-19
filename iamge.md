test locally docker build
![alt text](image.png)

local host 8081
![alt text](image-15.png)

![alt text](image-1.png)

Create the GitHub repo
![alt text](image-2.png)

Validate the Terraform
![alt text](image-3.png)
![alt text](image-4.png)

1f. Check your AWS access. This decides what we do in Step 2.
![alt text](image-7.png)
![alt text](image-5.png)
![alt text](image-6.png)

Step 2: Deploy
2a. Check the region setting. Your region line had a leading space.
![alt text](image-8.png)

2b. Bootstrap (run once; it creates the state bucket and the GitHub login role):
Import the bucket using us-east-1
![alt text](image-9.png)

Import GitHub OIDC
![alt text](image-10.png)

verify
![alt text](image-11.png)

Apply the changes
![alt text](image-12.png)

verify
![alt text](image-13.png)

2c. Add the GitHub settings. In your repo, go to Settings → Secrets and variables → Actions.

![alt text](image-14.png)