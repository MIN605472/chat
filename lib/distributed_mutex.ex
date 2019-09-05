defmodule RicartAgrawalaMutex do
  require Logger

  def init(members) do
    # Connect all of the nodes in 'members'
    Enum.each(members, fn m -> Node.connect(m) end)
    # Start process that holds the shared variables
    Agent.start_link(
      fn ->
        %{
          our_sequence_number: 0,
          highest_sequence_number: 0,
          outstanding_reply_count: 0,
          requesting_critical_section: false,
          reply_deferred: Map.new(members, fn m -> {m, false} end),
          defer_it: false
        }
      end,
      name: :shared_vars
    )

    Process.register(
      spawn_link(RicartAgrawalaMutex, :receive_reply_messages, []),
      :receive_reply_messages
    )

    Process.register(
      spawn_link(RicartAgrawalaMutex, :receive_request_messages, []),
      :receive_request_messages
    )

    Process.register(spawn_link(RicartAgrawalaMutex, :invoke_me, []), :invoke_me)
  end

  defp wait_for(key, value) do
    receive do
      {:wait_for, ^key, ^value} ->
        nil

      {:wait_for, _, _} ->
        wait_for(key, value)
    end
  end

  def invoke_me() do
    receive do
      {:invoke_me, fun} ->
        invoke_mutual_exclusion(fun)
    end

    invoke_me()
  end

  def invoke_mutual_exclusion(fun) do
    Logger.metadata(node: Node.self())
    # Request entry to our Critical Section
    # P(Shared_vars)
    # Choose a sequence number

    Agent.update(:shared_vars, fn state ->
      state = Map.update!(state, :requesting_critical_section, fn _ -> true end)
      highest_sequence_number = Map.get(state, :highest_sequence_number)
      state = Map.update!(state, :our_sequence_number, fn _ -> highest_sequence_number + 1 end)

      Map.update!(state, :outstanding_reply_count, fn _ ->
        map_size(Map.get(state, :reply_deferred)) - 1
      end)
    end)

    # V(Shared_vars)
    members =
      Agent.get(:shared_vars, fn state -> Map.get(state, :reply_deferred) |> Map.keys() end)

    our_sequence_number =
      Agent.get(:shared_vars, fn state -> Map.get(state, :our_sequence_number) end)

    Enum.each(members, fn m ->
      if m != Node.self(),
        do: send({:receive_request_messages, m}, {our_sequence_number, Node.self()})
    end)

    # Sent a REQUEST message containing our sequence number and our node number to all other nodes
    # Now wait for a REPLY from each of the other nodes
    Logger.info("Before wait_for(): #{inspect(Agent.get(:shared_vars, fn s -> s end))}")

    wait_for(:outstanding_reply_count, 0)
    # Critical Section Processing can be performed at this point
    Logger.info("In CS: #{inspect(Agent.get(:shared_vars, fn s -> s end))}")
    fun.()
    # Release the Critical Section
    Logger.info("Before releasing CS: #{inspect(Agent.get(:shared_vars, fn s -> s end))}")

    Agent.update(:shared_vars, fn state ->
      state = Map.update!(state, :requesting_critical_section, fn _ -> false end)

      Map.update!(state, :reply_deferred, fn v ->
        Enum.reduce(v, v, fn {node, deferred?}, acc ->
          if deferred? do
            send({:receive_reply_messages, node}, :reply)
            Map.update!(acc, node, fn _ -> false end)
          else
            acc
          end
        end)
      end)
    end)

    Logger.info("After releasing CS: #{inspect(Agent.get(:shared_vars, fn s -> s end))}")
  end

  def receive_request_messages do
    Logger.metadata(node: Node.self())
    # k is the sequence number being requested
    # j is the node number making the request
    # P(shared_vars)
    receive do
      {k, j} ->
        Logger.info(
          "Received REQUEST k=#{inspect(k)}, j=#{inspect(j)}, #{
            inspect(Agent.get(:shared_vars, fn s -> s end))
          }"
        )

        Agent.update(:shared_vars, fn state ->
          state = Map.update!(state, :highest_sequence_number, fn v -> max(v, k) end)
          our_sequence_number = Map.get(state, :our_sequence_number)
          requesting_critical_section = Map.get(state, :requesting_critical_section)

          state =
            Map.update!(state, :defer_it, fn _ ->
              requesting_critical_section &&
                (k > our_sequence_number || (k == our_sequence_number && j > Node.self()))
            end)

          if Map.get(state, :defer_it) do
            Map.update!(state, :reply_deferred, fn v -> Map.update!(v, j, fn _ -> true end) end)
          else
            send({:receive_reply_messages, j}, :reply)
            state
          end
        end)

        Logger.info("A: #{inspect(Agent.get(:shared_vars, fn s -> s end))}")

        # V(shared_vars)
        # Defer_it will be TRUE if we have priority over nodes j's request
        # if Agent.get(:shared_vars, fn state -> Map.get(state, :defer_it) end) do
        #   Agent.update(:shared_vars, fn state ->
        #     Map.update!(state, :reply_deferred, fn v ->
        #       Map.update!(v, j, fn _ -> true end)
        #     end)
        #   end)
        # else
        #   send({:receive_reply_messages, j}, :reply)
        # end
        Logger.info("B: #{inspect(Agent.get(:shared_vars, fn s -> s end))}")
    end

    receive_request_messages()
  end

  def receive_reply_messages() do
    receive do
      _ ->
        Logger.info("Received REPLY: #{inspect(Agent.get(:shared_vars, fn s -> s end))}")

        Agent.update(:shared_vars, fn state ->
          {outstanding_reply_count, state} =
            Map.get_and_update!(state, :outstanding_reply_count, fn v -> {v - 1, v - 1} end)

          send(:invoke_me, {:wait_for, :outstanding_reply_count, outstanding_reply_count})
          state
        end)
    end

    receive_reply_messages()
  end
end

defmodule Chat do
  def init(members) do
    RicartAgrawalaMutex.init(members)
    Process.register(spawn_link(Chat, :receive_msg, [[]]), :chat_msg_handler)
    # read_input(members)
  end

  def send_msg(msg, members) do
    send(
      :invoke_me,
      {:invoke_me,
       fn ->
         Enum.each(members, fn m -> send({:chat_msg_handler, m}, {self(), msg}) end)

         Enum.each(1..Enum.count(members), fn _ ->
           receive do
             :ack -> nil
           end
         end)
       end}
    )
  end

  defp read_input(members) do
    # msg = IO.gets(Kernel.inspect(Node.self()) <> ": ")
    msg = IO.gets("")
    send(:invoke_me, {:invoke_me, fn -> send_msg(msg, members) end})
    read_input(members)
  end

  def receive_msg(msgs) do
    receive do
      {pid, :get_all_msgs} ->
        send(pid, {Node.self(), msgs})
        receive_msg(msgs)

      {pid, msg} ->
        send(pid, :ack)
        msgs = msgs ++ [msg]
        receive_msg(msgs)
    end
  end
end
