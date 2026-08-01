FROM node:22-bookworm-slim AS build

WORKDIR /opt/app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-bookworm-slim

WORKDIR /opt/app
ENV NODE_ENV=production

COPY --from=build /opt/app ./
RUN npm ci --omit=dev && npm cache clean --force

EXPOSE 1337
CMD ["npm", "run", "start"]
