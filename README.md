# Setup Simulith

Start a local [Simulith](https://simulith.dev) runtime on a GitHub Actions runner and export the endpoint later steps use for the AWS CLI and SDKs.

```yaml
- uses: simulith/setup-action@v0.301.2
- run: curl -fsS "$SIMULITH_ENDPOINT/health"
```

Pin `uses:` to a release tag of this repository. Default mode runs `simulith/simulith:latest` from Docker Hub and maps host port **4566** to the container. The runtime inside the container listens on `0.0.0.0`. State is not mounted; it disappears when the job ends.

Product workflows in the Simulith repository call `./setup-action` from the same files.

## AWS CLI or SDK

The action exports dummy credentials (`AWS_ACCESS_KEY_ID=test`, `AWS_SECRET_ACCESS_KEY=test`), `AWS_DEFAULT_REGION`, `AWS_ENDPOINT_URL`, and `SIMULITH_ENDPOINT`.

```yaml
- uses: simulith/setup-action@v0.301.2
- run: aws dynamodb list-tables --endpoint-url "$SIMULITH_ENDPOINT"
```

`--endpoint-url` is the reliable form. `AWS_ENDPOINT_URL` is also set for AWS CLI v2.

## Inputs

| Input | Default | Role |
| --- | --- | --- |
| `mode` | `docker` | `docker` or `binary` |
| `version` | `latest` | Image tag, or GitHub Release tag in binary mode |
| `image` | `simulith/simulith` | Image name (docker mode) |
| `port` | `4566` | Host port |
| `region` | `us-east-1` | Exported AWS region |
| `container-name` | `simulith` | Docker container name |
| `timeout-seconds` | `60` | Wait for `GET /health` |

## Binary mode

`mode: binary` downloads `simulith_<version>_<os>_<arch>` from [Releases in this repository](https://github.com/simulith/setup-action/releases), checks `checksums.txt`, and caches the extracted binary with `actions/cache`. `version: latest` resolves the newest release before the cache key is chosen.

```yaml
- uses: simulith/setup-action@v0.301.2
  with:
    mode: binary
    version: v0.301.2
```

## Outputs

| Output | Meaning |
| --- | --- |
| `endpoint-url` | `http://127.0.0.1:<port>` |
| `container-name` | Docker container name |

## Docs

Guides and the compatibility matrix: [simulith/simulith-docs](https://github.com/simulith/simulith-docs).

## License

[MIT](LICENSE)
