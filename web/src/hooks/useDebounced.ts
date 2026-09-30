import { useEffect, useState } from "react";

/** `value`, once it has stopped changing for `ms`. Keeps typing from sending an RPC call per keystroke. */
export function useDebounced<T>(value: T, ms = 300): T {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    const id = setTimeout(() => setSettled(value), ms);
    return () => clearTimeout(id);
  }, [value, ms]);
  return settled;
}
