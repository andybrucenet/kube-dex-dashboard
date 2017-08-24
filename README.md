See [our article on Kubernetes Dashboard](https://www.softwareab.net/wordpress/kubernetes-dashboard-authentication-isolation/) for information on using this repo.

Here's a brief listing of what's in here:

* `dex/rbac` - Contains example service accounts, tokens, roles, and roleBindings
* `manifests` - Contains a single sample file with a Dashboard deployment, customized to a user.
* `scripts` - Example script for acquiring (and saving) a bearer token when `dex` is deployed to your Kubernetes cluster.

The files are not usable as-is; you will need to modify them for your environment.

At some point I may document the entire process for a local Kubernetes deployment, but no time for that now.

Hope this is useful...

