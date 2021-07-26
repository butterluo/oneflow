"""
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""
import unittest
from collections import OrderedDict

import numpy as np

import oneflow as flow
from test_util import GenArgList
from automated_test_util import *


def _test_eq(test_case, shape, device):
    arr1 = np.random.randn(*shape)
    arr2 = np.random.randn(*shape)
    input = flow.Tensor(arr1, dtype=flow.float32, device=flow.device(device))
    other = flow.Tensor(arr2, dtype=flow.float32, device=flow.device(device))

    of_out = flow.eq(input, other)
    of_out2 = flow.equal(input, other)
    np_out = np.equal(arr1, arr2)
    test_case.assertTrue(np.array_equal(of_out.numpy(), np_out))
    test_case.assertTrue(np.array_equal(of_out2.numpy(), np_out))


def _test_tensor_eq_operator(test_case, shape, device):
    arr1 = np.random.randn(*shape)
    arr2 = np.random.randn(*shape)
    input = flow.Tensor(arr1, dtype=flow.float32, device=flow.device(device))
    other = flow.Tensor(arr2, dtype=flow.float32, device=flow.device(device))

    of_out = input.eq(other)
    np_out = np.equal(arr1, arr2)
    test_case.assertTrue(np.array_equal(of_out.numpy(), np_out))


def _test_eq_int(test_case, shape, device):
    arr = np.random.randn(*shape)
    input = flow.Tensor(arr, dtype=flow.float32, device=flow.device(device))
    num = 1
    of_out = flow.eq(input, num)
    np_out = np.equal(arr, num)
    test_case.assertTrue(np.array_equal(of_out.numpy(), np_out))


def _test_tensor_eq_operator_int(test_case, shape, device):
    arr = np.random.randn(*shape)
    input = flow.Tensor(arr, dtype=flow.float32, device=flow.device(device))
    num = 1
    of_out = input.eq(num)
    np_out = np.equal(arr, num)
    test_case.assertTrue(np.array_equal(of_out.numpy(), np_out))


def _test_eq_float(test_case, shape, device):
    arr = np.random.randn(*shape)
    input = flow.Tensor(arr, dtype=flow.float32, device=flow.device(device))
    num = 1.0
    of_out = flow.eq(input, num)
    np_out = np.equal(arr, num)
    test_case.assertTrue(np.array_equal(of_out.numpy(), np_out))


def _test_tensor_eq_operator_float(test_case, shape, device):
    arr = np.random.randn(*shape)
    input = flow.Tensor(arr, dtype=flow.float32, device=flow.device(device))
    num = 1.0
    of_out = input.eq(num)
    np_out = np.equal(arr, num)
    test_case.assertTrue(np.array_equal(of_out.numpy(), np_out))


@flow.unittest.skip_unless_1n1d()
class TestEq(flow.unittest.TestCase):
    def test_eq(test_case):
        arg_dict = OrderedDict()
        arg_dict["test_func"] = [
            _test_eq,
            _test_tensor_eq_operator,
            _test_eq_int,
            _test_tensor_eq_operator_int,
            _test_eq_float,
            _test_tensor_eq_operator_float,
        ]
        arg_dict["shape"] = [(2, 3), (2, 3, 4), (2, 4, 5, 6)]
        arg_dict["device"] = ["cpu", "cuda"]
        for arg in GenArgList(arg_dict):
            arg[0](test_case, *arg[1:])

    @autotest(auto_backward=False)
    def test_flow_eq_with_random_data(test_case):
        device = random_device()
        shape = random_tensor().value().shape
        x = random_pytorch_tensor(len(shape), *shape, requires_grad=False).to(device)
        y = random_pytorch_tensor(len(shape), *shape, requires_grad=False).to(device)
        return torch.eq(x, y)
    
    @autotest(auto_backward=False)
    def test_flow_eq_with_same_random_data(test_case):
        device = random_device()
        shape = random_tensor().value().shape
        x = random_pytorch_tensor(len(shape), *shape, requires_grad=False).to(device)
        return torch.eq(x, x)
    
    @autotest(auto_backward=False)
    def test_flow_tensor_eq_with_random_data(test_case):
        device = random_device()
        shape = random_tensor().value().shape
        x = random_pytorch_tensor(len(shape), *shape, requires_grad=False).to(device)
        y = random_pytorch_tensor(len(shape), *shape, requires_grad=False).to(device)
        return x.eq(y)
    
    @autotest(auto_backward=False)
    def test_flow_tensor_eq_with_same_random_data(test_case):
        device = random_device()
        shape = random_tensor().value().shape
        x = random_pytorch_tensor(len(shape), *shape, requires_grad=False).to(device)
        return x.eq(x)
    

if __name__ == "__main__":
    unittest.main()
