=== /cm/local/apps/cm-setup/lib/python3.12/site-packages/urwid/event_loop/zmq_loop.py:266
            del self._idle_callbacks[handle]
        except KeyError:
            return False

        return True

    def _entering_idle(self) -> None:
        for callback in list(self._idle_callbacks.values()):
            callback()

    def run(self) -> None:
        """
        Start the event loop. Exit the loop when any callback raises an
        exception. If :exc:`ExitMainLoop` is raised, exit cleanly.
        """
        with contextlib.suppress(ExitMainLoop):
            while True:
                try:
                    self._loop()
                except zmq.error.ZMQError as exc:  # noqa: PERF203
                    if exc.errno != errno.EINTR:
                        raise

    def _loop(self) -> None:
        """
        A single iteration of the event loop.
        """
        state = "wait"  # default state not expecting any action
        if self._alarms or self._did_something:
            timeout = 0
            if self._alarms:
                state = "alarm"
                timeout = max(0.0, self._alarms[0][0] - time.time())
            if self._did_something and (not self._alarms or (self._alarms and timeout > 0)):
                state = "idle"
                timeout = 0
            ready = dict(self._poller.poll(timeout * 1000))
        else:
            ready = dict(self._poller.poll())

        if not ready:
            if state == "idle":
                self._entering_idle()
                self._did_something = False
            elif state == "alarm":
                _due, _tie_break, callback = heapq.heappop(self._alarms)
=== /cm/local/apps/cm-setup/lib/python3.12/site-packages/cmsetup/plugins/kubernetes/stages/stages.py:1423
        )


class SetRebootRequired(stage.MarkNodesRestartRequired):
    @property
    def entities_to_apply(
        self,
    ) -> Collection[pythoncm.entity.Node | pythoncm.entity.Category | pythoncm.entity.ConfigurationOverlay]:
        return {node for node in self.state['kube_set'].nodes if not isinstance(node, pythoncm.entity.HeadNode)}

    @property
    def reason(self) -> str | Collection[str]:
        return 'Kubernetes cleanup'


class CheckKubeNodesReportedReady(stage.Stage):
    @property
    def enabled(self) -> bool:
        return self.state['kc']  # type: ignore[no-any-return]

    @tenacity.retry(
        retry=tenacity.retry_if_exception_type(
            (
                api.NotReadyException,
                urllib3.exceptions.MaxRetryError,
            )
        ),
        stop=tenacity.stop_after_delay(kube_constants.DEF_TIMEOUT_SEC),
        wait=tenacity.wait_fixed(kube_constants.DEF_RETRY_DELAY),
        retry_error_cls=exceptions.RetryError,
        reraise=True,
    )
    def _wait_all_kubelet_ready(self) -> None:
        kc = self.state['kc']
        kubectl = api.Kubectl(confpath=f'/root/.kube/config-{kc.name}')
        hostnames: list[str] = [
            node_status.hostname for node_status in kubectl.get_nodes_status() if not node_status.ready
        ]

        if hostnames:
            msg = f"Kubelet not ready for some nodes: {', '.join(hostnames)}."
            raise api.NotReadyException(msg)

    def run(self) -> None:
        def handle_error() -> None:
            LOGGER.info(
=== /cm/local/apps/cm-setup/lib/python3.12/site-packages/cmsetup/plugins/kubernetes/stages/stages.py:2219
        result = typing.cast(
            list[pythoncm.entity.OSServiceConfig],
            self.cluster.parallel.service_status(
                nodes=list(self._nodes),
                name='containerd',
            ),
        )
        node_uuids: dict[uuid.UUID | int, str] = {n.uuid: n.hostname for n in self._nodes}
        for res in result:
            if res.ref_node_uuid not in node_uuids:
                # In practice we have retrieved results that had a UUID('00000000-0000-0000-0000-000000000000')
                # Assuming the retrieved statuses are eventually consistent we'll retry..
                LOGGER.debug(f"Retrieved status UUID {res.ref_node_uuid} likely invalid or unexpected.")
                raise api.NotReadyException("Retrieved service status refers to unexpected Node")
            node_hostname = node_uuids[res.ref_node_uuid]
            if res.status.name != "UP":
                msg = f"Node {node_hostname} containerd service is not running, status is: {res.status.name}"
                LOGGER.debug(msg)
                raise api.NotReadyException(msg)

    @tenacity.retry(
        retry=tenacity.retry_if_exception_type((api.NotReadyException,)),
        stop=tenacity.stop_after_delay(kube_constants.DEF_TIMEOUT_SEC),
        wait=tenacity.wait_fixed(kube_constants.DEF_RETRY_DELAY),
        retry_error_cls=exceptions.RetryError,
        reraise=True,
    )
    def _wait_for_containerd_runtime_status_ready(self) -> None:
        sock = consts.CONTAINER_RUNTIME_ENDPOINTS[self.config["container_runtime"]]

        # read containerd info via crictl from all nodes
        cmd = f"crictl -r {sock} info"
        _, status = self.cluster.parallel.execute(
            list(self._nodes), cmd, wait=True, timeout=kube_constants.DEF_TIMEOUT_SEC
        )

        # inspect the output for each of them
        for node in self._nodes:
            json_str: str | None = status.get_output(node.uuid)
            if not json_str:
                msg = f"Containerd socket on {node.hostname} not ready."
                LOGGER.debug(msg)
                raise api.NotReadyException(msg)

            if not self._check_containerd_runtime_ready(json_str):
                msg = f"Containerd socket on {node.hostname} does not report runtime is ready."
=== /cm/local/apps/cm-setup/lib/python3.12/site-packages/cmsetup/shared/stages/other.py:182
        wait_sec = 10

        # calling /ready?name=cod returns "ready" if all the subsystems of cmd are up and running
        url_suffix = f"/ready?wait={wait_sec}&name=cod"

        full_url = None
        with open(conf.cmdurlfile, encoding="utf-8") as fh:
            if url := fh.read():
                full_url = url + url_suffix
            else:
                raise ValueError(f"Failed to get cmd url from {conf.cmdurlfile}")
        return full_url

    @staticmethod
    def _get_ssl_ctx() -> ssl.SSLContext:
        # Passing the ssl ctx to urlopen later is optional. However we have to do it
        # in order to make the urlopen ignore (not verify) the CMDaemon's certificate.
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx

    @tenacity.retry(
        wait=tenacity.wait_fixed(1),
        stop=tenacity.stop_after_delay(600),
        retry=tenacity.retry_if_exception_type(TimeoutError),
        reraise=True,
    )
    def _wait_for_subsystems(self, full_url: str, ssl_ctx: ssl.SSLContext) -> None:
        # This function throws TimeoutError exceptions to communicate to the
        # tenacity.retry wrapper that it should consider retrying.

        log.debug(f"Waiting for CMD subsystems to become ready: {full_url}")

        try:
            with urlopen(full_url, context=ssl_ctx, timeout=10) as fh:
                content = fh.read().decode("utf-8")
        except OSError as e:
            # IOError is the parent class of urllib exception types, but it also
            # covers socket related exceptions.
            # Note: CMD returns 503 if any of the specified subsystems is not ready.
            log.debug(f"Error: {e}")
            raise TimeoutError(f"IOError: {e}") from e

        if content != "ready":
            raise TimeoutError(f"The content was not 'ready', it was: {content!r}")
