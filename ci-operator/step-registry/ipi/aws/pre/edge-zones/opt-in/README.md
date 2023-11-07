# ipi-aws-pre-edge-zones-opt-in | local execution

Procedures to execute the step `ipi-aws-pre-edge-zones-opt-in` locally, in development environment.

- Adjust the following environment variables according to your setup/needs:

```sh
# Path to the release repository
export RELEASE_REPO=$HOME/go/src/github.com/openshift/release/

# AWS region.
export AWS_REGION=us-east-1
export AWS_CREDENTIALS_FILE=${HOME}/.aws/credentials

# Zone Type used in step. Allowed values: local-zone | wavelength-zone
export EDGE_ZONE_TYPES=local-zone
```

- Setup environment variables used in the step:

```bash
CI_WORKDIR=$(mktemp -d)
echo "CI_WORKDIR created: $CI_WORKDIR"

export LEASED_RESOURCE=$AWS_REGION
export CLUSTER_PROFILE_DIR=$CI_WORKDIR
export SHARED_DIR=$CI_WORKDIR

ln -svf ${AWS_CREDENTIALS_FILE} ${CLUSTER_PROFILE_DIR}/.awscred
```

- Run the script and check the results:

```bash

COMMAND_PATH=${RELEASE_REPO}/ci-operator/step-registry/ipi/aws/pre/edge-zones/opt-in/ipi-aws-pre-edge-zones-opt-in-commands.sh

bash $COMMAND_PATH
ls -la $SHARED_DIR/*.txt
```

- Remove tmp data:

```sh
rm -rfv $CI_WORKDIR
```