enum ClickHouseConfiguration {
  static let configuration = """
    <clickhouse><logger><level>warning</level><log>/data/server.log</log><errorlog>/data/server.err.log</errorlog><size>1M</size><count>1</count></logger>
    <path>/data/store/</path><tmp_path>/data/tmp/</tmp_path><user_files_path>/data/user_files/</user_files_path><users_config>/lab/users.xml</users_config>
    <listen_host>127.0.0.1</listen_host><tcp_port>9000</tcp_port><http_port>8123</http_port><max_server_memory_usage>671088640</max_server_memory_usage>
    <max_thread_pool_size>64</max_thread_pool_size><background_pool_size>2</background_pool_size><background_schedule_pool_size>2</background_schedule_pool_size>
    <background_streaming_schedule_pool_size>1</background_streaming_schedule_pool_size><background_move_pool_size>1</background_move_pool_size><background_fetches_pool_size>1</background_fetches_pool_size><background_common_pool_size>1</background_common_pool_size>
    <background_message_broker_schedule_pool_size>1</background_message_broker_schedule_pool_size><background_distributed_schedule_pool_size>1</background_distributed_schedule_pool_size><background_buffer_flush_schedule_pool_size>1</background_buffer_flush_schedule_pool_size>
    <merge_tree><number_of_free_entries_in_pool_to_execute_mutation>0</number_of_free_entries_in_pool_to_execute_mutation><number_of_free_entries_in_pool_to_lower_max_size_of_merge>0</number_of_free_entries_in_pool_to_lower_max_size_of_merge><number_of_free_entries_in_pool_to_execute_optimize_entire_partition>0</number_of_free_entries_in_pool_to_execute_optimize_entire_partition></merge_tree>
    <mark_cache_size>8388608</mark_cache_size><uncompressed_cache_size>8388608</uncompressed_cache_size><mlock_executable>false</mlock_executable>
    </clickhouse>
    """
  static let users = """
    <clickhouse><profiles><default><max_memory_usage>201326592</max_memory_usage><max_threads>1</max_threads><max_execution_time>8</max_execution_time><timeout_before_checking_execution_speed>0</timeout_before_checking_execution_speed><max_rows_to_read>500000</max_rows_to_read><max_bytes_to_read>100663296</max_bytes_to_read><max_result_rows>1000</max_result_rows></default></profiles><users><default><password></password><profile>default</profile><quota>default</quota><networks><ip>127.0.0.1</ip></networks></default></users><quotas><default><interval><duration>3600</duration><queries>100</queries><errors>30</errors><result_rows>10000</result_rows><read_rows>20000000</read_rows><execution_time>120</execution_time></interval></default></quotas></clickhouse>
    """
}
