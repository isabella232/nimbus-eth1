# uTP testing infrastructure 

Testing infrastructure which enables to test uTP implementation over different
network conditions on local machine.

Highly based on tools developed to test quic protocol:

[quic-interop-runner](https://github.com/marten-seemann/quic-interop-runner)

[quic-network-simulator](https://github.com/marten-seemann/quic-network-simulator)

## Prerequisities

- Machine with docker installed

- nimbus-eth1 set-up to run `make utp_test`

## How it works

Test setup uses docker compose to start 3 docker containers:
- client - which is instance of uTP test app
- server - which is instance of uTP test app
- sim - which is instance with ns3 network simulator with several pre-compiled scenarios

The networking is setup in such way that network traffic is routed from client to server
and server to client thorugh sim which decideds what to do with flowing packets

Explanation from [quic-network-simulator](https://github.com/marten-seemann/quic-network-simulator):

```
The framework uses two networks on the host machine: `leftnet` (IPv4
193.167.0.0/24, IPv6 fd00:cafe:cafe:0::/64) and `rightnet` (IPv4
193.167.100.0/24, IPv6 fd00:cafe:cafe:100::/64). `leftnet` is connected to the
client docker image, and `rightnet` is connected to the server. The ns-3
simulation sits in the middle and forwards packets between `leftnet` and
`rightnet`
```

## Practicalities

For now process is semi-manual (TODO automate this as much as possible)

To run integration testing scenarios with different network conditions

```
1. cd nimbus-eth1/
2. docker build -t test-utp --build-arg BRANCH_NAME={branch-name} fluffy/tools/utp_testing/docker
3. SCENARIO="scenario_details" docker-compose -f fluffy/tools/utp_testing/docker/docker-compose.yml up

For example:
SCENARIO="drop-rate --delay=15ms --bandwidth=10Mbps --queue=25 --rate_to_client=0 --rate_to_server=0" docker-compose -f fluffy/tools/utp_testing/docker/docker-compose.yml up
would start `drop-rate` scenario with specified delay, bandwith, and different drop rates
4. make utp-test
```

All scenarios are specified in: [scenarios](https://github.com/marten-seemann/quic-network-simulator/tree/master/sim/scenarios)
