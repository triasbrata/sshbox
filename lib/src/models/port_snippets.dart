/// A common service and the port it is on.
typedef PortSnippet = ({String name, int port});

/// Offered as chips under a port forward's Port. All 1024 or above, so each
/// can open on the tablet as it is.
const List<PortSnippet> portSnippets = [
  (name: 'PostgreSQL', port: 5432),
  (name: 'MySQL/MariaDB', port: 3306),
  (name: 'Redis', port: 6379),
  (name: 'MongoDB', port: 27017),
  (name: 'SQL Server', port: 1433),
  (name: 'Elasticsearch', port: 9200),
  (name: 'RabbitMQ', port: 5672),
  (name: 'PostgREST', port: 3000),
  (name: 'Vite', port: 5173),
  (name: 'Web', port: 8080),
];

/// The snippet's service on [port], if any: PostgreSQL on 5432.
String? serviceOn(int port) =>
    portSnippets.where((snippet) => snippet.port == port).firstOrNull?.name;
