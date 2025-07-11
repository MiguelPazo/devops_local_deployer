# Local deployer

[![Docker Hub](https://img.shields.io/docker/pulls/miguelpazo/devops-local-deployer?style=flat-square)](https://hub.docker.com/r/miguelpazo/devops-local-deployer)

Image available on Docker Hub: [miguelpazo/devops-local-deployer](https://hub.docker.com/r/miguelpazo/devops-local-deployer)

Build image

```bash
docker build --no-cache --network host -t deployer .

docker run -it --rm \
    --hostname deployer \
    -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN \
    -e GIT_USERNAME=$GIT_USERNAME \
    -e GIT_TOKEN=$GIT_TOKEN \
    -e SERVERLESS_ACCESS_KEY=$SERVERLESS_ACCESS_KEY \
    -v ~/.aws:/root/.aws \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $(pwd)/scripts:/scripts \
    -v /path/deploy_projects:/deploy_projects \
    deployer bash
```


