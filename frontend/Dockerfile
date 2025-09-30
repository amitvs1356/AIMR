FROM node:20-alpine
WORKDIR /app
COPY package.json /app/
RUN npm install || true
COPY . /app
RUN npm run build || true
CMD ["docker-entrypoint.sh","sh","-c","node server.js || npm start || npx next start -p 6100"]
