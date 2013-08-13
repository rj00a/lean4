/*
Copyright (c) 2013 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.

Author: Leonardo de Moura
*/
#pragma once
#include <exception>
#include <string>

namespace lean {

class exception : public std::exception {
protected:
    std::string m_msg;
public:
    exception(char const * msg);
    exception(std::string const & msg);
    exception(exception const & ex);
    virtual ~exception() noexcept;
    virtual char const * what() const noexcept;
};

class parser_exception : public exception {
protected:
    unsigned m_line;
    unsigned m_pos;
public:
    parser_exception(char const * msg, unsigned l, unsigned p);
    parser_exception(std::string const & msg, unsigned l, unsigned p);
    parser_exception(parser_exception const & ex);
    virtual ~parser_exception() noexcept;
    virtual char const * what() const noexcept;
    unsigned get_line() const { return m_line; }
    unsigned get_pos() const { return m_pos; }
};
}
