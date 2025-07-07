Final image

```bash
docker build --no-cache --network host -t deployer .
```

Test image

```bash
docker build --no-cache --network host -f DockerfileTest -t deployertest .

docker run -it --rm \
    --hostname deployertest \
    -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN \
    -e GIT_USERNAME=$GIT_USERNAME \
    -e GIT_TOKEN=$GIT_TOKEN \
    -e SERVERLESS_ACCESS_KEY=$SERVERLESS_ACCESS_KEY \
    -v ~/.aws:/root/.aws \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $(pwd)/src:/deploy_scripts \
    -v /path/deploy_projects:/deploy_projects \
    deployertest bash
```


