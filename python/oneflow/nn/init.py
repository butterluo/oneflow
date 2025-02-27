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
import os
import math

import numpy as np

import oneflow as flow
from oneflow.ops.util.initializer_util import (
    calc_gain as calculate_gain,
    calc_fan,
    get_data_format,
)
from oneflow.framework.tensor import Tensor
import oneflow.framework.dtype as dtype_util
import oneflow.ops.initializer_register as initializer_register


def _init_by_initializer_conf(tensor, initializer_conf, random_seed=None):
    # NOTE: initializing weight should not enable autograd mode
    if random_seed is None:
        random_seed = flow.default_generator.seed()
    shape = tuple(tensor.shape)
    initializer = initializer_register.get_initializer(
        initializer_conf, random_seed, shape
    )

    np_arr = initializer_register.generate_values_by_initializer(
        initializer, shape, tensor.dtype
    )
    with flow.no_grad():
        if tensor.is_global:
            src_tensor = flow.tensor(np_arr)
            src_tensor = src_tensor.to_global(
                placement=tensor.placement,
                sbp=tuple(flow.sbp.broadcast for _ in range(len(tensor.sbp))),
            )
            tensor.copy_(src_tensor)
        else:
            shared_mem_tensor = flow.from_numpy(np_arr)
            tensor[...] = shared_mem_tensor
    return tensor


def uniform_(tensor, a=0.0, b=1.0):
    r"""
    
    Fills the input Tensor with values drawn from the uniform
    distribution :math:`\mathcal{U}(a, b)`.

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Args:
        tensor: an n-dimensional `oneflow.Tensor`
        a: the lower bound of the uniform distribution
        b: the upper bound of the uniform distribution

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.uniform_(w)
    """
    assert a <= b, "b must be greater than or equal to a,but got {%d} vs {%d}" % (b, a)
    with flow.no_grad():
        return flow._C.uniform_(tensor, a, b)


def normal_(tensor, mean=0.0, std=1.0):
    r"""
    
    Fills the input Tensor with values drawn from the normal
    distribution :math:`\mathcal{N}(\text{mean}, \text{std}^2)`.

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Args:
        tensor: an n-dimensional `oneflow.Tensor`
        mean: the mean of the normal distribution
        std: the standard deviation of the normal distribution

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.normal_(w)
    """
    with flow.no_grad():
        if tensor.is_local:
            return flow.normal(mean=mean, std=std, size=tensor.shape, out=tensor)
        else:
            return flow.normal(
                mean=mean,
                std=std,
                size=tensor.shape,
                out=tensor,
                placement=tensor.placement,
                sbp=tensor.sbp,
            )


def xavier_uniform_(tensor, gain=1.0, *, data_format="NCHW"):
    r"""
    Fills the input `Tensor` with values according to the method
    described in `Understanding the difficulty of training deep feedforward
    neural networks` - Glorot, X. & Bengio, Y. (2010), using a uniform
    distribution. The resulting tensor will have values sampled from
    :math:`\mathcal{U}(-a, a)` where

    .. math::
        a = \text{gain} \times \sqrt{\frac{6}{\text{fan_in} + \text{fan_out}}}

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Also known as Glorot initialization.

    Args:
        tensor: an n-dimensional `oneflow.Tensor`
        gain: an optional scaling factor

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.xavier_uniform_(w, gain=nn.init.calculate_gain('relu'))
    """
    fan = calc_fan(tensor.shape, "fan_sum", get_data_format(data_format))
    std = gain * math.sqrt(2.0 / fan)
    bound = math.sqrt(3.0) * std
    return uniform_(tensor, -bound, bound)


def xavier_normal_(tensor, gain=1.0, *, data_format="NCHW"):
    r"""
    Fills the input `Tensor` with values according to the method
    described in `Understanding the difficulty of training deep feedforward
    neural networks` - Glorot, X. & Bengio, Y. (2010), using a normal
    distribution. The resulting tensor will have values sampled from
    :math:`\mathcal{N}(0, \text{std}^2)` where

    .. math::
        \text{std} = \text{gain} \times \sqrt{\frac{2}{\text{fan_in} + \text{fan_out}}}

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Also known as Glorot initialization.

    Args:
        tensor: an n-dimensional `oneflow.Tensor`
        gain: an optional scaling factor

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.xavier_normal_(w)
    """
    if os.getenv("ONEFLOW_ENABLE_NHWC") == "1":
        data_format = "NHWC"
    fan = calc_fan(tensor.shape, "fan_sum", get_data_format(data_format))
    std = gain * math.sqrt(2.0 / fan)
    return normal_(tensor, 0.0, std)


def orthogonal_(tensor, gain=1.0):
    r"""
    Fills the input `Tensor` with a (semi) orthogonal matrix, as
    described in `Exact solutions to the nonlinear dynamics of learning in deep
    linear neural networks` - Saxe, A. et al. (2013). The input tensor must have
    at least 2 dimensions, and for tensors with more than 2 dimensions the
    trailing dimensions are flattened.

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Args:
        tensor: an n-dimensional `torch.Tensor`, where :math:`n \geq 2`
        gain: optional scaling factor

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.orthogonal_(w)
    """
    with flow.no_grad():
        return tensor.orthogonal_(gain)


def kaiming_uniform_(
    tensor, a=0, mode="fan_in", nonlinearity="leaky_relu", *, data_format="NCHW"
):
    r"""
    Fills the input `Tensor` with values according to the method
    described in `Delving deep into rectifiers: Surpassing human-level
    performance on ImageNet classification` - He, K. et al. (2015), using a
    uniform distribution. The resulting tensor will have values sampled from
    :math:`\mathcal{U}(-\text{bound}, \text{bound})` where

    .. math::
        \text{bound} = \text{gain} \times \sqrt{\frac{3}{\text{fan_mode}}}
    
    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Also known as He initialization.

    Args:
        tensor: an n-dimensional `oneflow.Tensor`
        a: the negative slope of the rectifier used after this layer (only
            used with ``'leaky_relu'``)
        mode: either ``'fan_in'`` (default) or ``'fan_out'``. Choosing ``'fan_in'``
            preserves the magnitude of the variance of the weights in the
            forward pass. Choosing ``'fan_out'`` preserves the magnitudes in the
            backwards pass.
        nonlinearity: the non-linear function (`nn.functional` name),
            recommended to use only with ``'relu'`` or ``'leaky_relu'`` (default).

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.kaiming_uniform_(w, mode='fan_in', nonlinearity='relu')
    """
    if os.getenv("ONEFLOW_ENABLE_NHWC") == "1":
        data_format = "NHWC"
    fan = calc_fan(tensor.shape, mode, get_data_format(data_format))
    gain = calculate_gain(nonlinearity, a)
    std = gain / math.sqrt(fan)
    bound = math.sqrt(3.0) * std
    return uniform_(tensor, -bound, bound)


def kaiming_normal_(
    tensor, a=0, mode="fan_in", nonlinearity="leaky_relu", *, data_format="NCHW"
):
    r"""    
    Fills the input `Tensor` with values according to the method
    described in `Delving deep into rectifiers: Surpassing human-level
    performance on ImageNet classification` - He, K. et al. (2015), using a
    normal distribution. The resulting tensor will have values sampled from
    :math:`\mathcal{N}(0, \text{std}^2)` where

    .. math::
        \text{std} = \frac{\text{gain}}{\sqrt{\text{fan_mode}}}

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Also known as He initialization.

    Args:
        tensor: an n-dimensional `oneflow.Tensor`
        a: the negative slope of the rectifier used after this layer (only
            used with ``'leaky_relu'``)
        mode: either ``'fan_in'`` (default) or ``'fan_out'``. Choosing ``'fan_in'``
            preserves the magnitude of the variance of the weights in the
            forward pass. Choosing ``'fan_out'`` preserves the magnitudes in the
            backwards pass.
        nonlinearity: the non-linear function (`nn.functional` name),
            recommended to use only with ``'relu'`` or ``'leaky_relu'`` (default).

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.kaiming_normal_(w, mode='fan_out', nonlinearity='relu')
    """
    if os.getenv("ONEFLOW_ENABLE_NHWC") == "1":
        data_format = "NHWC"
    assert mode in ["fan_in", "fan_out"]
    fan = calc_fan(tensor.shape, mode, get_data_format(data_format))
    gain = calculate_gain(nonlinearity, a)
    std = gain / math.sqrt(fan)
    return normal_(tensor, 0.0, std)


def trunc_normal_(tensor, mean=0.0, std=1.0, a=-2.0, b=2.0):
    with flow.no_grad():
        return tensor.normal_(mean, std).clamp_(a, b)


def constant_(tensor, val):
    r"""
    
    Fills the input Tensor with the value :math:`\text{val}`.

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Args:
        tensor: an n-dimensional `oneflow.Tensor`
        val: the value to fill the tensor with

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.constant_(w, 0.3)
    """
    with flow.no_grad():
        tensor[...] = val
        return tensor


def ones_(tensor):
    r"""
    
    Fills the input Tensor with the scalar value `1`.

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Args:
        tensor: an n-dimensional `oneflow.Tensor`

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.ones_(w)
    """
    with flow.no_grad():
        return constant_(tensor, 1)


def zeros_(tensor):
    r"""
    
    Fills the input Tensor with the scalar value `0`.

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Args:
        tensor: an n-dimensional `oneflow.Tensor`

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.zeros_(w)
    """
    with flow.no_grad():
        return constant_(tensor, 0)


def eye_(tensor):
    r"""
    
    Fills the 2-dimensional input `Tensor` with the identity
    matrix. Preserves the identity of the inputs in `Linear` layers, where as
    many inputs are preserved as possible.

    The interface is consistent with PyTorch.
    The documentation is referenced from: https://pytorch.org/docs/1.10/nn.init.html.

    Args:
        tensor: a 2-dimensional `oneflow.Tensor`

    Examples:
        >>> w = flow.empty(3, 5)
        >>> nn.init.eye_(w)
    """
    if tensor.ndimension() != 2:
        raise ValueError("Only tensors with 2 dimensions are supported")
    with flow.no_grad():
        # TODO: use flow._C.eye_ after eye_op supporting non-contiguous kernel
        assign_tensor = flow.from_numpy(
            np.eye(
                tensor.shape[0],
                tensor.shape[1],
                dtype=dtype_util.convert_oneflow_dtype_to_numpy_dtype(tensor.dtype),
            )
        )
        tensor[...] = assign_tensor
        return tensor


def _calculate_fan_in_and_fan_out(tensor):
    dimensions = tensor.ndimension()
    if dimensions < 2:
        raise ValueError(
            "Fan in and fan out can not be computed for tensor with fewer than 2 dimensions"
        )
    num_input_fmaps = tensor.size(1)
    num_output_fmaps = tensor.size(0)
    receptive_field_size = 1
    if tensor.ndimension() > 2:
        for s in tensor.size()[2:]:
            receptive_field_size *= s
    fan_in = num_input_fmaps * receptive_field_size
    fan_out = num_output_fmaps * receptive_field_size
    return (fan_in, fan_out)
