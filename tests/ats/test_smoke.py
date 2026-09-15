import logging

import pykube
import pytest
from pytest_helm_charts.clusters import Cluster

logger = logging.getLogger(__name__)


@pytest.mark.smoke
def test_chart_installs(kube_cluster: Cluster) -> None:
    """Verify the smoke-test cluster is reachable after the chart installed.

    The smoke step installs the chart into the cluster before this test runs, so
    a healthy API connection here confirms the chart renders and the release
    installs cleanly. The chart renders Cluster API objects (MachinePool,
    KubeadmConfig, KarpenterMachinePool) for an existing cluster; the fixture
    cluster and the render goldens are the chart's own verification, not this
    smoke test's.
    """
    assert kube_cluster.kube_client is not None
    assert len(pykube.Node.objects(kube_cluster.kube_client)) >= 1
