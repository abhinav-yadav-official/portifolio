# portifolio

Static homepage for https://abhiyadav.in.

The misspelled repository name is intentional: the GitHub repo is
`abhinav-yadav-official/portifolio`.

## Development

```sh
task test
```

Open `index.html` directly in a browser for local review.

## Deploy

```sh
task deploy -- abhiyadav.in
```

The deploy keeps `/var/www/html/shared/` intact so LeetDrill extension downloads
continue to be served by the leetdrill deployment.
