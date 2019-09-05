defmodule DistributedMutexTest do
  use ExUnit.Case
  doctest Chat
  doctest RicartAgrawalaMutex

  test "same message queue on all nodes" do
    chat_members = Application.get_env(Mix.Project.get().project[:app], :members)
    Enum.each(chat_members, fn m -> Node.connect(m) end)
    Enum.each(chat_members, fn m -> Node.spawn_link(m, Chat, :init, [chat_members]) end)
    Process.sleep(1000)

    msgs_per_member = 10

    Enum.each(1..msgs_per_member, fn v ->
      Enum.each(chat_members, fn m ->
        msg = Integer.to_string(v) <> inspect(m)
        IO.inspect(Node.spawn_link(m, Chat, :send_msg, [msg, chat_members]))
      end)
    end)

    Process.sleep(50000)

    msgs_from_all_nodes =
      Enum.map(chat_members, fn m ->
        send({:chat_msg_handler, m}, {self(), :get_all_msgs})

        receive do
          {node, msgs} ->
            msgs
        end
      end)

    # IO.inspect(msgs_from_all_nodes)
    uniq = Enum.uniq(msgs_from_all_nodes)
    assert Enum.count(uniq) == 1
    assert Enum.count(hd(uniq)) == msgs_per_member * Enum.count(chat_members)
  end
end
