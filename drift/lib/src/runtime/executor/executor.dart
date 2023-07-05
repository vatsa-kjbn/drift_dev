import 'dart:async';

import 'package:collection/collection.dart';
import 'package:drift/backends.dart';
import 'package:drift/drift.dart' show OpeningDetails;

/// A query executor is responsible for executing statements on a database and
/// return their results in a raw form.
///
/// This is an internal api of drift, which can break often. If you want to
/// implement custom database backends, consider using the new `backends` API.
/// The [NativeDatabase implementation](https://github.com/simolus3/drift/blob/develop/drift/lib/src/ffi/database.dart)
/// might be useful as a reference. If you want to write your own database
/// engine to use with drift and run into issues, please consider creating an
/// issue.
abstract class QueryExecutor {
  /// The [SqlDialect] to use for this database engine.
  SqlDialect get dialect;

  /// Opens the executor, if it has not yet been opened.
  Future<bool> ensureOpen(QueryExecutorUser user);

  /// Runs a select statement with the given variables and returns the raw
  /// results.
  Future<List<Map<String, Object?>>> runSelect(
      String statement, List<Object?> args);

  /// Runs an insert statement with the given variables. Returns the row id or
  /// the auto_increment id of the inserted row.
  Future<int> runInsert(String statement, List<Object?> args);

  /// Runs an update statement with the given variables and returns how many
  /// rows where affected.
  Future<int> runUpdate(String statement, List<Object?> args);

  /// Runs an delete statement and returns how many rows where affected.
  Future<int> runDelete(String statement, List<Object?> args);

  /// Runs a custom SQL statement without any variables. The result of that
  /// statement will be ignored.
  Future<void> runCustom(String statement, [List<Object?>? args]);

  /// Prepares and runs [statements].
  ///
  /// Running them doesn't need to happen in a transaction. When using drift's
  /// batch api, drift will call this method from a transaction either way. This
  /// method mainly exists to save duplicate parsing costs, allowing each
  /// statement to be prepared only once.
  Future<void> runBatched(BatchedStatements statements);

  /// Starts a [TransactionExecutor].
  TransactionExecutor beginTransaction();

  /// Closes this database connection and releases all resources associated with
  /// it. Implementations should also handle [close] calls in a state where the
  /// database isn't open.
  Future<void> close() async {
    // no-op per default for backwards compatibility
  }
}

/// Callbacks passed to [QueryExecutor.ensureOpen] to run schema migrations when
/// the database is first opened.
abstract class QueryExecutorUser {
  /// The schema version to set on the database when it's opened.
  int get schemaVersion;

  /// A callbacks that runs after the database connection has been established,
  /// but before any other query is sent.
  ///
  /// The query executor will wait for this future to complete before running
  /// any other query. Queries running on the [executor] are an exception to
  /// this, they can be used to run migrations.
  /// No matter how often [QueryExecutor.ensureOpen] is called, this method will
  /// not be called more than once.
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details);
}

const _equality = ListEquality<Object?>();

/// Stores information needed to run batched statements in the order they were
/// issued without preparing statements multiple times.
class BatchedStatements {
  /// All sql statements that need to be prepared.
  ///
  /// A statement might run multiple times with different arguments.
  final List<String> statements;

  /// Stores which sql statement should be run with what arguments.
  final List<ArgumentsForBatchedStatement> arguments;

  /// Creates a collection of batched statements by splitting the sql and the
  /// bound arguments.
  BatchedStatements(this.statements, this.arguments);

  @override
  int get hashCode {
    return Object.hash(_equality.hash(statements), _equality.hash(arguments));
  }

  @override
  bool operator ==(Object other) {
    return other is BatchedStatements &&
        _equality.equals(other.statements, statements) &&
        _equality.equals(other.arguments, arguments);
  }

  @override
  String toString() {
    return 'BatchedStatements($statements, $arguments)';
  }
}

/// Instruction to run a batched sql statement with the arguments provided.
class ArgumentsForBatchedStatement {
  /// Index of the sql statement in the [BatchedStatements.statements] of the
  /// [BatchedStatements] containing this argument set.
  final int statementIndex;

  /// Bound arguments for the referenced statement.
  final List<Object?> arguments;

  /// Used internally by drift.
  ArgumentsForBatchedStatement(this.statementIndex, this.arguments);

  @override
  int get hashCode {
    return Object.hash(statementIndex, _equality);
  }

  @override
  bool operator ==(Object other) {
    return other is ArgumentsForBatchedStatement &&
        other.statementIndex == statementIndex &&
        _equality.equals(other.arguments, arguments);
  }

  @override
  String toString() {
    return 'ArgumentsForBatchedStatement($statementIndex, $arguments)';
  }
}

/// A [QueryExecutor] that runs multiple queries atomically.
abstract class TransactionExecutor extends QueryExecutor {
  /// Whether this transaction executor supports nesting transactions by calling
  /// [beginTransaction] on it.
  bool get supportsNestedTransactions;

  /// Completes the transaction. No further queries may be sent to to this
  /// [QueryExecutor] after this method was called.
  ///
  /// This may be called before [ensureOpen] was awaited, implementations must
  /// support this. That state implies that no query was sent, so it should be
  /// a no-op.
  Future<void> send();

  /// Cancels this transaction. No further queries may be sent ot this
  /// [QueryExecutor] after this method was called.
  ///
  /// This may be called before [ensureOpen] was awaited, implementations must
  /// support this. That state implies that no query was sent, so it should be
  /// a no-op.
  Future<void> rollback();
}

/// Extension to wrap a [QueryExecutor] with a [QueryInterceptor].
extension ApplyInterceptor on QueryExecutor {
  /// Returns a [QueryExecutor] that will use `this` executor internally, but
  /// with calls intercepted by the given [interceptor].
  ///
  /// This can be used to, for instance, write a custom statement logger or to
  /// retry failing statements automatically.
  QueryExecutor interceptWith(QueryInterceptor interceptor) {
    final $this = this;

    if ($this is TransactionExecutor) {
      return _InterceptedTransactionExecutor($this, interceptor);
    } else {
      return _InterceptedExecutor($this, interceptor);
    }
  }
}

/// An eunm for statement methods used by drift.
enum RunStatementMode {
  /// A statement without information about the kind.
  /// See also [QueryExecutor.runCustom].
  custom,

  /// An insert statement - see [QueryExecutor.runInsert].
  insert,

  /// An update statement - see [QueryExecutor.runUpdate].
  update,

  /// A delete statement - see [QueryExecutor.delete].
  delete
}

/// An interceptor for SQL queries.
///
/// This wraps an existing [QueryExecutor] implemented by drift, and by default
/// does nothing. However, specific methods can be overridden to customize the
/// behavior of an existing query executor.
abstract class QueryInterceptor {
  /// Intercept [QueryExecutor.dialect] calls.
  SqlDialect dialect(QueryExecutor executor) => executor.dialect;

  /// Intercept [QueryExecutor.beginTransaction] calls.
  TransactionExecutor beginTransaction(QueryExecutor parent) =>
      parent.beginTransaction();

  /// Intercept [TransactionExecutor.supportsNestedTransactions] calls.
  bool transactionCanBeNested(TransactionExecutor inner) {
    return inner.supportsNestedTransactions;
  }

  /// Intercept [QueryExecutor.close] calls.
  Future<void> close(QueryExecutor inner) => inner.close();

  /// Intercept [TransactionExecutor.send] calls.
  Future<void> commitTransaction(TransactionExecutor inner) {
    return inner.send();
  }

  /// Intercept [TransactionExecutor.rollback] calls.
  Future<void> rollbackTransaction(TransactionExecutor inner) {
    return inner.rollback();
  }

  /// Intercept [QueryExecutor.ensureOpen] calls.
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      executor.ensureOpen(user);

  /// Intercept [QueryExecutor.runBatched] calls.
  Future<void> runBatched(
      QueryExecutor executor, BatchedStatements statements) {
    return executor.runBatched(statements);
  }

  /// Intercept [QueryExecutor.runInsert], [QueryExecutor.runUpdate],
  /// [QueryExecutor.runDelete] or [QueryExecutor.runCustom] calls.
  Future<int> runSql(QueryExecutor executor, RunStatementMode mode,
      String statement, List<Object?> args) {
    return switch (mode) {
      RunStatementMode.custom =>
        executor.runCustom(statement, args).then((_) => 0),
      RunStatementMode.insert => executor.runInsert(statement, args),
      RunStatementMode.delete => executor.runDelete(statement, args),
      RunStatementMode.update => executor.runUpdate(statement, args),
    };
  }

  /// Intercept [QueryExecutor.runSelect] calls.
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    return executor.runSelect(statement, args);
  }
}

class _InterceptedExecutor extends QueryExecutor {
  final QueryExecutor _inner;
  final QueryInterceptor _interceptor;

  _InterceptedExecutor(this._inner, this._interceptor);

  @override
  TransactionExecutor beginTransaction() =>
      _interceptor.beginTransaction(_inner);

  @override
  SqlDialect get dialect => _interceptor.dialect(_inner);

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) {
    return _interceptor.ensureOpen(_inner, user);
  }

  @override
  Future<void> runBatched(BatchedStatements statements) {
    return _interceptor.runBatched(_inner, statements);
  }

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) {
    return _interceptor.runSql(
        _inner, RunStatementMode.custom, statement, args ?? const []);
  }

  @override
  Future<int> runDelete(String statement, List<Object?> args) {
    return _interceptor.runSql(
        _inner, RunStatementMode.delete, statement, args);
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) {
    return _interceptor.runSql(
        _inner, RunStatementMode.insert, statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
      String statement, List<Object?> args) {
    return _interceptor.runSelect(_inner, statement, args);
  }

  @override
  Future<int> runUpdate(String statement, List<Object?> args) {
    return _interceptor.runSql(
        _inner, RunStatementMode.update, statement, args);
  }

  @override
  Future<void> close() {
    return _interceptor.close(_inner);
  }
}

class _InterceptedTransactionExecutor extends _InterceptedExecutor
    implements TransactionExecutor {
  _InterceptedTransactionExecutor(super.inner, super.interceptor);

  @override
  Future<void> rollback() {
    return _interceptor.rollbackTransaction(_inner as TransactionExecutor);
  }

  @override
  Future<void> send() {
    return _interceptor.commitTransaction(_inner as TransactionExecutor);
  }

  @override
  bool get supportsNestedTransactions =>
      _interceptor.transactionCanBeNested(_inner as TransactionExecutor);
}
