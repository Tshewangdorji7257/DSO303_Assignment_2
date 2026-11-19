FROM node:20-alpine
WORKDIR /app

# Trust the Amazon RDS certificate authority so TLS to RDS is encrypted AND verified
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /etc/ssl/rds-global-bundle.pem
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/rds-global-bundle.pem

COPY package*.json ./
RUN npm install --omit=dev
COPY server.js .
USER node
EXPOSE 8080
CMD ["node", "server.js"]