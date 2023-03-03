#pragma once

#include <erl_nif.h>
#include <string>
#include <vector>

namespace nif {

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *msg)
{
  ERL_NIF_TERM a;
  if (enif_make_existing_atom(env, msg, &a, ERL_NIF_LATIN1)) {
    return a;
  } else {
    return enif_make_atom(env, msg);
  }
}

static ERL_NIF_TERM error(ErlNifEnv *env, const char *msg)
{
  ERL_NIF_TERM atom_error = atom(env, "error");
  ERL_NIF_TERM reason;
  unsigned char * ptr;
  size_t len = strlen(msg);
  if ((ptr = enif_make_new_binary(env, len, &reason)) != nullptr) {
    strcpy((char *)ptr, msg);
    return enif_make_tuple2(env, atom_error, reason);
  } else {
    ERL_NIF_TERM msg_term = enif_make_string(env, msg, ERL_NIF_LATIN1);
    return enif_make_tuple2(env, atom_error, msg_term);
  }
}

static ERL_NIF_TERM make_string(ErlNifEnv *env, const char *msg, bool& success) {
  ERL_NIF_TERM erl_string;
  unsigned char * ptr;
  size_t len = strlen(msg);
  if ((ptr = enif_make_new_binary(env, len, &erl_string)) != nullptr) {
    strcpy((char *)ptr, msg);
    success = true;
    return erl_string;
  } else {
    success = false;
    return 0;
  }
}

int get_atom(ErlNifEnv *env, ERL_NIF_TERM term, std::string &var)
{
  unsigned atom_length;
  if (!enif_get_atom_length(env, term, &atom_length, ERL_NIF_LATIN1))
  {
    return 0;
  }

  var.resize(atom_length + 1);

  if (!enif_get_atom(env, term, &(*(var.begin())), var.size(), ERL_NIF_LATIN1))
    return 0;

  var.resize(atom_length);

  return 1;
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, bool *var)
{
  std::string bool_atom;
  if (!get_atom(env, term, bool_atom))
    return 0;
  *var = (bool_atom == "true");
  return 1;
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, int *var)
{
  return enif_get_int(env, term, var);
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, int64_t *var)
{
  return enif_get_int64(env, term, reinterpret_cast<ErlNifSInt64 *>(var));
}

int get(ErlNifEnv *env, ERL_NIF_TERM term, std::string &var)
{
  ErlNifBinary bin;
  if (enif_inspect_binary(env, term, &bin))
  {
    var = std::string((const char *)bin.data, bin.size);
    return 1;
  }

  unsigned len;
  if (enif_get_list_length(env, term, &len)) {
    var.resize(len + 1);
    int ret = enif_get_string(env, term, &*(var.begin()), var.size(), ERL_NIF_LATIN1);

    if (ret > 0)
    {
      var.resize(ret - 1);
    }
    else if (ret == 0)
    {
      var.resize(0);
    }
    return ret;
  }

  return 0;
}

int get_list(ErlNifEnv *env, ERL_NIF_TERM list, std::vector<std::string> &var)
{
  unsigned int length;
  if (!enif_get_list_length(env, list, &length))
    return 0;
  var.reserve(length);
  ERL_NIF_TERM head, tail;

  while (enif_get_list_cell(env, list, &head, &tail))
  {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, head, &bin)) {
      return 0;
    }
    var.push_back(std::string((const char *)bin.data, bin.size));
    list = tail;
  }
  return 1;
}

int get_env(ErlNifEnv *env, ERL_NIF_TERM env_map, std::vector<std::string> &envs) {
  if (!enif_is_map(env, env_map)) return 0;
  ERL_NIF_TERM key, value;
  ErlNifMapIterator iter;
  enif_map_iterator_create(env, env_map, &iter, ERL_NIF_MAP_ITERATOR_FIRST);

  while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
      std::string var_name, var_value, entry;
      if (!get(env, key, var_name) || !get(env, value, var_value)) {
        return 0;
      }
      entry = var_name + "=" + var_value;
      envs.emplace_back(entry);
      enif_map_iterator_next(env, &iter);
  }
  enif_map_iterator_destroy(env, &iter);
  return 1;
}

} // namespace nif
